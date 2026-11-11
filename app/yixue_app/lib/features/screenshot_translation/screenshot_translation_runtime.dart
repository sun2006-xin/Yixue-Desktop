import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_screenshot/screenshot.dart';
import 'package:yixue_app/core/dictionary_service.dart';
import 'package:yixue_app/core/quick_translation_service.dart';
import 'package:yixue_app/core/retryable_single_flight_operation.dart';
import 'package:yixue_app/core/screenshot_translation_capture_service.dart';
import 'package:yixue_app/core/screenshot_translation_image_comparison.dart';
import 'package:yixue_app/core/screenshot_translation_image_store.dart';
import 'package:yixue_app/core/screenshot_translation_ocr_layout.dart';
import 'package:yixue_app/core/screenshot_translation_preferences.dart';
import 'package:yixue_app/core/screenshot_translation_window_protocol.dart';
import 'package:yixue_app/core/translation_execution_route.dart';

enum ScreenshotTranslationStatus {
  capturing,
  recognizing,
  translating,
  completed,
  empty,
  failed,
  cancelled,
}

enum ScreenshotTranslationImageSaveStatus {
  notRequested,
  unavailable,
  saving,
  saved,
  failed,
  invalidated,
  cacheLimitReached,
}

final class ScreenshotTranslationRetryCacheFullException extends StateError {
  ScreenshotTranslationRetryCacheFullException() : super(userMessage);

  static const userMessage = '重试缓存已满，记录未删除；先完成/清理待保存截图后重试';
}

final class ScreenshotTranslationRetryableImageSave {
  const ScreenshotTranslationRetryableImageSave({required this.captureId});

  final String captureId;

  /// Compatibility alias for earlier UI/test call sites.
  String get historyEntryId => captureId;
}

final class _ScreenshotImageSnapshot {
  const _ScreenshotImageSnapshot({
    required this.bytes,
    required this.allowed,
    this.lease,
  });

  final Uint8List bytes;
  final bool allowed;
  final ScreenshotTranslationImageWriteLease? lease;
}

/// One in-memory screenshot. Only recognized/translated text reaches history.
final class ScreenshotTranslationSession {
  const ScreenshotTranslationSession({
    required this.id,
    this.historyEntryId,
    this.bounds,
    this.imageBytes,
    this.recognizedText = '',
    this.ocrLayout,
    this.translatedText,
    this.translatedSourceBlockIndices,
    this.direction = TranslationDirection.englishToChinese,
    this.directionManuallyOverridden = false,
    this.translationRoute,
    this.imageSaveAllowed = false,
    this.imageSaveStatus = ScreenshotTranslationImageSaveStatus.notRequested,
    this.regionPinned = false,
    this.regionContentChanged,
    required this.status,
    this.errorCode,
  });

  final String id;
  final String? historyEntryId;
  final ScreenshotBounds? bounds;
  final Uint8List? imageBytes;
  final String recognizedText;
  final ScreenshotTranslationOcrLayout? ocrLayout;
  final String? translatedText;
  final List<int>? translatedSourceBlockIndices;
  final TranslationDirection direction;
  final bool directionManuallyOverridden;
  final TranslationExecutionRoute? translationRoute;
  final bool imageSaveAllowed;
  final ScreenshotTranslationImageSaveStatus imageSaveStatus;
  final bool regionPinned;
  final bool? regionContentChanged;
  final ScreenshotTranslationStatus status;
  final String? errorCode;

  String? get imageSaveMessage => switch (imageSaveStatus) {
    ScreenshotTranslationImageSaveStatus.failed => '原图保存失败，可重试保存。',
    ScreenshotTranslationImageSaveStatus.cacheLimitReached =>
      imageBytes == null
          ? '原图保存失败：历史原图重试缓存容量不足，此图已无法重试，请重新截屏。'
          : '历史原图重试缓存容量不足；当前结果仍可重试保存，关闭结果或重新截屏后无法重试此图。',
    ScreenshotTranslationImageSaveStatus.unavailable => '原图存储不可用。',
    ScreenshotTranslationImageSaveStatus.invalidated =>
      '原图保存重试已失效；请以归档操作结果确认图片状态。',
    _ => null,
  };

  ScreenshotTranslationSession withState(
    ScreenshotTranslationStatus status, {
    String? recognizedText,
    String? translatedText,
    TranslationDirection? direction,
    bool? directionManuallyOverridden,
    TranslationExecutionRoute? translationRoute,
    bool clearTranslationRoute = false,
    bool? imageSaveAllowed,
    ScreenshotTranslationImageSaveStatus? imageSaveStatus,
    bool? regionPinned,
    bool? regionContentChanged,
    ScreenshotTranslationOcrLayout? ocrLayout,
    List<int>? translatedSourceBlockIndices,
    bool clearTranslationAlignment = false,
    String? errorCode,
    String? historyEntryId,
  }) => ScreenshotTranslationSession(
    id: id,
    historyEntryId: historyEntryId ?? this.historyEntryId,
    bounds: bounds,
    imageBytes: imageBytes,
    recognizedText: recognizedText ?? this.recognizedText,
    ocrLayout: ocrLayout ?? this.ocrLayout,
    translatedText: translatedText,
    translatedSourceBlockIndices: clearTranslationAlignment
        ? null
        : translatedText == null
        ? null
        : translatedSourceBlockIndices ?? this.translatedSourceBlockIndices,
    direction: direction ?? this.direction,
    directionManuallyOverridden:
        directionManuallyOverridden ?? this.directionManuallyOverridden,
    translationRoute: clearTranslationRoute
        ? null
        : translationRoute ?? this.translationRoute,
    imageSaveAllowed: imageSaveAllowed ?? this.imageSaveAllowed,
    imageSaveStatus: imageSaveStatus ?? this.imageSaveStatus,
    regionPinned: regionPinned ?? this.regionPinned,
    regionContentChanged: regionContentChanged ?? this.regionContentChanged,
    status: status,
    errorCode: errorCode,
  );

  Map<String, Object?> toMap({bool includeImageBytes = true}) => {
    'id': id,
    'historyEntryId': historyEntryId,
    if (includeImageBytes) 'imageBytes': imageBytes,
    'recognizedText': recognizedText,
    if (ocrLayout != null) 'ocrLayout': ocrLayout!.toMap(),
    'translatedText': translatedText,
    if (translatedSourceBlockIndices != null)
      'translatedSourceBlockIndices': translatedSourceBlockIndices,
    'direction': direction.name,
    'directionManuallyOverridden': directionManuallyOverridden,
    'translationRoute': translationRoute?.toMap(),
    'imageSaveAllowed': imageSaveAllowed,
    'imageSaveStatus': imageSaveStatus.name,
    'regionPinned': regionPinned,
    'regionContentChanged': regionContentChanged,
    'imageSaveMessage': imageSaveMessage,
    'status': status.name,
    'errorCode': errorCode,
    if (bounds case final bounds?)
      'bounds': {
        'left': bounds.left,
        'top': bounds.top,
        'width': bounds.width,
        'height': bounds.height,
      },
  };

  /// Reuses [previous] image bytes only when the session ID is unchanged.
  /// Callers must confirm the child window requested reuse before passing it.
  factory ScreenshotTranslationSession.fromMap(
    Map value, {
    ScreenshotTranslationSession? previous,
  }) {
    final id = value['id'] as String;
    final previousForSession = previous?.id == id ? previous : null;
    final rawBounds = value['bounds'];
    return ScreenshotTranslationSession(
      id: id,
      historyEntryId:
          value['historyEntryId'] as String? ??
          previousForSession?.historyEntryId ??
          (value['status'] == ScreenshotTranslationStatus.completed.name
              ? id
              : null),
      imageBytes: value.containsKey('imageBytes')
          ? value['imageBytes'] as Uint8List?
          : previousForSession?.imageBytes,
      bounds: rawBounds is Map
          ? ScreenshotBounds(
              left: rawBounds['left'] as int,
              top: rawBounds['top'] as int,
              width: rawBounds['width'] as int,
              height: rawBounds['height'] as int,
            )
          : null,
      recognizedText: value['recognizedText'] as String,
      ocrLayout: ScreenshotTranslationOcrLayout.tryParse(value['ocrLayout']),
      translatedText: value['translatedText'] as String?,
      translatedSourceBlockIndices:
          value['translatedSourceBlockIndices'] is List &&
              (value['translatedSourceBlockIndices'] as List).every(
                (index) => index is int,
              )
          ? List<int>.unmodifiable(
              (value['translatedSourceBlockIndices'] as List).cast<int>(),
            )
          : null,
      direction: TranslationDirection.values.byName(
        value['direction'] as String,
      ),
      directionManuallyOverridden:
          value['directionManuallyOverridden'] as bool? ?? false,
      translationRoute: value['translationRoute'] is Map
          ? TranslationExecutionRoute.fromMap(value['translationRoute'] as Map)
          : null,
      imageSaveAllowed: value['imageSaveAllowed'] as bool? ?? false,
      imageSaveStatus: ScreenshotTranslationImageSaveStatus.values.byName(
        value['imageSaveStatus'] as String? ??
            ScreenshotTranslationImageSaveStatus.notRequested.name,
      ),
      regionPinned: value['regionPinned'] as bool? ?? false,
      regionContentChanged: value['regionContentChanged'] as bool?,
      status: ScreenshotTranslationStatus.values.byName(
        value['status'] as String,
      ),
      errorCode: value['errorCode'] as String?,
    );
  }
}

/// Chooses between the currently supported English/Chinese screenshot routes.
///
/// Han characters provide Chinese evidence. Common acronyms and mixed-case
/// brand names are discounted; English function words and a sufficient amount
/// of ordinary Latin text provide stronger evidence. This remains a
/// two-language heuristic, not general-purpose language identification.
const _screenshotTranslationEnglishFunctionWords = <String>{
  'a',
  'an',
  'and',
  'are',
  'as',
  'at',
  'be',
  'been',
  'but',
  'by',
  'can',
  'could',
  'did',
  'do',
  'does',
  'for',
  'from',
  'had',
  'has',
  'have',
  'he',
  'her',
  'him',
  'his',
  'i',
  'if',
  'in',
  'into',
  'is',
  'it',
  'me',
  'my',
  'not',
  'of',
  'on',
  'or',
  'our',
  'she',
  'should',
  'than',
  'that',
  'the',
  'their',
  'them',
  'then',
  'there',
  'these',
  'they',
  'this',
  'those',
  'to',
  'was',
  'we',
  'were',
  'will',
  'with',
  'would',
  'you',
  'your',
};
const _screenshotTranslationCommonAcronyms = <String>{
  'BIOS',
  'CUDA',
  'CSS',
  'DHCP',
  'GPIO',
  'HTML',
  'HTTP',
  'HTTPS',
  'JSON',
  'MQTT',
  'PDF',
  'REST',
  'SMTP',
  'SNMP',
  'UART',
  'UEFI',
  'URL',
  'UUID',
  'XML',
  'YAML',
};
final _screenshotTranslationLatinTokenPattern = RegExp(r'[A-Za-z]+');

TranslationDirection detectScreenshotTranslationDirection(
  String sourceText, {
  required TranslationDirection fallback,
}) {
  var hanCharacters = 0;
  var englishFunctionWordCount = 0;
  var englishContentWordCount = 0;
  var englishProseCharacters = 0;
  var longUppercaseWordCount = 0;
  final latinTokens = _screenshotTranslationLatinTokenPattern
      .allMatches(sourceText)
      .map((match) => match.group(0)!)
      .toList(growable: false);

  for (final rune in sourceText.runes) {
    if (isScreenshotTranslationHanIdeograph(rune)) {
      hanCharacters++;
    }
  }
  for (final token in latinTokens) {
    final lowercase = token.toLowerCase();
    if (_screenshotTranslationEnglishFunctionWords.contains(lowercase)) {
      englishFunctionWordCount++;
    }

    final isAcronym = token.length > 1 && token == token.toUpperCase();
    var hasInternalUppercase = false;
    for (var index = 1; index < token.length; index++) {
      final codeUnit = token.codeUnitAt(index);
      if (codeUnit >= 0x41 && codeUnit <= 0x5A) {
        hasInternalUppercase = true;
        break;
      }
    }
    final isShortAcronym =
        isAcronym &&
        (token.length <= 3 ||
            _screenshotTranslationCommonAcronyms.contains(token));
    if (isShortAcronym ||
        (hasInternalUppercase && !isAcronym) ||
        token.length < 2) {
      continue;
    }

    englishProseCharacters += token.length;
    if (!_screenshotTranslationEnglishFunctionWords.contains(lowercase)) {
      englishContentWordCount++;
      if (isAcronym) longUppercaseWordCount++;
    }
  }

  if (hanCharacters == 0) {
    return latinTokens.isEmpty
        ? fallback
        : TranslationDirection.englishToChinese;
  }
  if (latinTokens.isEmpty) return TranslationDirection.chineseToEnglish;

  final latinTextOutweighsHan = englishProseCharacters > hanCharacters * 2;
  final englishEvidenceIsClear =
      latinTextOutweighsHan &&
      ((englishFunctionWordCount >= 2 && englishContentWordCount >= 1) ||
          englishContentWordCount >= 2 ||
          (englishContentWordCount == 1 && longUppercaseWordCount == 1));
  return englishEvidenceIsClear
      ? TranslationDirection.englishToChinese
      : TranslationDirection.chineseToEnglish;
}

typedef ScreenshotTranslationRunner = Future<String> Function(
  String source,
  TranslationDirection direction, {
  required String origin,
  required String historyEntryId,
  required String screenshotCaptureId,
});

typedef ScreenshotTranslationRecognizer = Future<String> Function(
  CapturedData capture, [
  ScreenshotTranslationCancellationToken? cancellationToken,
]);

typedef ScreenshotTranslationDocumentRecognizer =
    Future<ScreenshotTranslationOcrDocument> Function(
      CapturedData capture, [
      ScreenshotTranslationCancellationToken? cancellationToken,
    ]);

typedef ScreenshotTranslationCaptureGuard = Future<CapturedData?> Function(
  Future<CapturedData?> Function() capture,
);

typedef ScreenshotTranslationRouteAwareRunner = Future<String> Function(
  String source,
  TranslationDirection direction, {
  required String origin,
  required String historyEntryId,
  required String screenshotCaptureId,
  required void Function(TranslationExecutionRoute route) onRouteSelected,
});

const screenshotTranslationMaxAlignedOcrBlocks = 16;
const screenshotTranslationMaxPerBlockFallbackRequests = 4;

bool canTranslateScreenshotOcrBlocksWithAlignment(
  ScreenshotTranslationOcrLayout? layout, {
  required String source,
}) =>
    layout != null &&
    layout.sourceText == source &&
    layout.blocks.length <= screenshotTranslationMaxAlignedOcrBlocks &&
    ScreenshotTranslationOcrLayout.tryParse(layout.toMap()) != null;

final class ScreenshotTranslationDocumentTranslation {
  const ScreenshotTranslationDocumentTranslation({
    required this.translatedText,
    this.translatedSourceBlockIndices,
  });

  final String translatedText;
  final List<int>? translatedSourceBlockIndices;
}

typedef ScreenshotTranslationDocumentRouteAwareRunner =
    Future<ScreenshotTranslationDocumentTranslation> Function(
      String source,
      ScreenshotTranslationOcrLayout layout,
      TranslationDirection direction, {
      required String origin,
      required String historyEntryId,
      required String screenshotCaptureId,
      required void Function(TranslationExecutionRoute route) onRouteSelected,
    });

/// Translates OCR blocks individually so the caller can retain the exact
/// source-block identity for each returned translation. If the provider
/// changes paragraph structure, the text is preserved but spatial alignment
/// is omitted by the strict overlay validator.
Future<ScreenshotTranslationDocumentTranslation>
translateScreenshotOcrLayoutBlocks(
  ScreenshotTranslationOcrLayout layout, {
  required Future<String> Function(String sourceBlock, int blockIndex)
  translateBlock,
}) async {
  if (!canTranslateScreenshotOcrBlocksWithAlignment(
    layout,
    source: layout.sourceText,
  )) {
    throw const FormatException('screenshot_layout_alignment_unsupported');
  }
  final translatedBlocks = <String>[];
  for (var index = 0; index < layout.blocks.length; index++) {
    final translated = await translateBlock(layout.blocks[index].text, index);
    if (translated.trim().isEmpty) {
      throw const FormatException('empty_screenshot_block_translation');
    }
    translatedBlocks.add(translated.trim());
  }
  final translatedText = translatedBlocks.join('\n\n');
  final indices = List<int>.generate(
    translatedBlocks.length,
    (index) => index,
    growable: false,
  );
  final isAligned =
      pairScreenshotTranslationOverlay(
        recognizedText: layout.sourceText,
        translatedText: translatedText,
        layout: layout,
        translatedSourceBlockIndices: indices,
      ) !=
      null;
  return ScreenshotTranslationDocumentTranslation(
    translatedText: translatedText,
    translatedSourceBlockIndices: isAligned
        ? List<int>.unmodifiable(indices)
        : null,
  );
}

/// Holds compact boundary markers so OCR blocks fit in one provider request
/// and map back only when every marker returns once in the original order.
final class ScreenshotTranslationOcrMarkup {
  ScreenshotTranslationOcrMarkup._({
    required this.sourceText,
    required this.startMarker,
    required List<String> boundaryMarkers,
    required this.endMarker,
  }) : boundaryMarkers = List<String>.unmodifiable(boundaryMarkers);

  final String sourceText;
  final String startMarker;
  final List<String> boundaryMarkers;
  final String endMarker;

  ScreenshotTranslationDocumentTranslation? parse(
    ScreenshotTranslationOcrLayout layout,
    String translatedText,
  ) {
    if (layout.blocks.length != boundaryMarkers.length + 1) {
      return null;
    }

    final markers = <String>[startMarker, ...boundaryMarkers, endMarker];
    if (markers.toSet().length != markers.length) return null;

    final markerOffsets = <int>[];
    for (final marker in markers) {
      final offset = translatedText.indexOf(marker);
      if (offset < 0 ||
          translatedText.indexOf(marker, offset + marker.length) >= 0) {
        return null;
      }
      markerOffsets.add(offset);
    }
    if (translatedText.substring(0, markerOffsets.first).trim().isNotEmpty ||
        translatedText
            .substring(markerOffsets.last + endMarker.length)
            .trim()
            .isNotEmpty) {
      return null;
    }
    for (var index = 1; index < markerOffsets.length; index++) {
      if (markerOffsets[index] <= markerOffsets[index - 1]) return null;
    }

    final translatedBlocks = <String>[];
    for (var index = 0; index < layout.blocks.length; index++) {
      final contentStart = markerOffsets[index] + markers[index].length;
      final translatedBlock = translatedText
          .substring(contentStart, markerOffsets[index + 1])
          .trim();
      if (translatedBlock.isEmpty) return null;
      translatedBlocks.add(translatedBlock);
    }

    final indices = List<int>.generate(
      translatedBlocks.length,
      (index) => index,
      growable: false,
    );
    final documentText = translatedBlocks.join('\n\n');
    final isAligned =
        pairScreenshotTranslationOverlay(
          recognizedText: layout.sourceText,
          translatedText: documentText,
          layout: layout,
          translatedSourceBlockIndices: indices,
        ) !=
        null;
    return ScreenshotTranslationDocumentTranslation(
      translatedText: documentText,
      translatedSourceBlockIndices: isAligned
          ? List<int>.unmodifiable(indices)
          : null,
    );
  }
}

const _screenshotOcrMarkerCharacters = <String>[
  '⟦',
  '⟧',
  '①',
  '②',
  '③',
  '④',
  '⑤',
  '⑥',
  '⑦',
  '⑧',
  '⑨',
  '⑩',
  '⑪',
  '⑫',
  '⑬',
  '⑭',
  '⑮',
  '⑯',
  '⑰',
  '⑱',
  '⑲',
  '⑳',
  '㉑',
  '㉒',
  '㉓',
  '㉔',
  '㉕',
  '㉖',
  '㉗',
  '㉘',
  '㉙',
  '㉚',
  '㉛',
  '㉜',
  '㉝',
  '㉞',
  '㉟',
  '㊱',
  '㊲',
  '㊳',
  '㊴',
  '㊵',
  '㊶',
  '㊷',
  '㊸',
  '㊹',
  '㊺',
  '㊻',
  '㊼',
  '㊽',
  '㊾',
  '㊿',
  '◆',
  '◇',
  '●',
  '○',
  '■',
  '□',
  '▲',
  '△',
  '▼',
  '▽',
  '▶',
  '▷',
  '◀',
  '◁',
  '◈',
  '◉',
  '◎',
  '※',
  '§',
  '¶',
  '†',
  '‡',
  '⊕',
  '⊖',
  '⊗',
  '⊙',
  '↗',
  '↘',
  '↙',
  '↖',
  '⇧',
  '⇩',
  '⇦',
  '⇨',
];

ScreenshotTranslationOcrMarkup? buildScreenshotTranslationOcrMarkup(
  ScreenshotTranslationOcrLayout layout, {
  required String markerNamespace,
}) {
  if (!RegExp(r'^[A-Za-z0-9_-]{1,80}$').hasMatch(markerNamespace)) {
    throw ArgumentError.value(markerNamespace, 'markerNamespace');
  }
  if (!canTranslateScreenshotOcrBlocksWithAlignment(
    layout,
    source: layout.sourceText,
  )) {
    return null;
  }

  // One-code-unit symbols replace paragraph separators or delimit the whole
  // document. This keeps long aligned OCR requests inside the provider limit.
  final availableMarkers = _screenshotOcrMarkerCharacters
      .where((marker) => !layout.sourceText.contains(marker))
      .toList(growable: false);
  final requiredMarkerCount = layout.blocks.length + 1;
  if (availableMarkers.length < requiredMarkerCount) return null;
  final markerOffset =
      (markerNamespace.hashCode & 0x7fffffff) % availableMarkers.length;
  final selectedMarkers = List<String>.generate(
    requiredMarkerCount,
    (index) =>
        availableMarkers[(markerOffset + index) % availableMarkers.length],
    growable: false,
  );
  final startMarker = selectedMarkers.first;
  final boundaryMarkers = selectedMarkers.sublist(
    1,
    selectedMarkers.length - 1,
  );
  final endMarker = selectedMarkers.last;
  final source = StringBuffer()
    ..write(startMarker)
    ..write(layout.blocks.first.text);
  for (var index = 1; index < layout.blocks.length; index++) {
    source
      ..write(boundaryMarkers[index - 1])
      ..write(layout.blocks[index].text);
  }
  source.write(endMarker);
  if (source.length > screenshotTranslationMaxSourceCharacters) return null;
  return ScreenshotTranslationOcrMarkup._(
    sourceText: source.toString(),
    startMarker: startMarker,
    boundaryMarkers: boundaryMarkers,
    endMarker: endMarker,
  );
}

bool shouldFallbackScreenshotTranslationOnException(Exception error) {
  const retryableFormatCodes = <String>{
    'suspicious_model_output',
    'format_integrity_failed',
  };
  return error is QuickTranslationException &&
      retryableFormatCodes.contains(error.code);
}

Future<ScreenshotTranslationDocumentTranslation>
translateScreenshotOcrMarkupOrFallback({
  required ScreenshotTranslationOcrLayout layout,
  required ScreenshotTranslationOcrMarkup? markup,
  required Future<String> Function(String markedText) translateMarkedText,
  Future<String> Function(String sourceBlock, int blockIndex)? translateBlock,
  required Future<String> Function(String sourceText) translateWholeText,
  required bool Function(Exception error) shouldFallbackOnException,
}) async {
  if (markup != null) {
    try {
      final markedTranslation = await translateMarkedText(markup.sourceText);
      final mapped = markup.parse(layout, markedTranslation);
      if (mapped?.translatedSourceBlockIndices != null) return mapped!;
      if (translateBlock != null &&
          layout.blocks.length <=
              screenshotTranslationMaxPerBlockFallbackRequests) {
        return await translateScreenshotOcrLayoutBlocks(
          layout,
          translateBlock: translateBlock,
        );
      }
    } on Exception catch (error) {
      if (!shouldFallbackOnException(error)) rethrow;
    }
  }
  final translatedText = await translateWholeText(layout.sourceText);
  if (translatedText.trim().isEmpty) {
    throw const FormatException('empty_screenshot_document_translation');
  }
  return ScreenshotTranslationDocumentTranslation(
    translatedText: translatedText.trim(),
  );
}

abstract interface class ScreenshotTranslationResultHandle {
  Future<void> update(ScreenshotTranslationSession? session);
  Future<void> hide();
}

final class ScreenshotTranslationResultHandleSupersededException
    implements Exception {
  const ScreenshotTranslationResultHandleSupersededException();
}

typedef ScreenshotDictionaryLookupLauncher = Future<void> Function({
  String? sourceContext,
  String? sourceRecognizedText,
  String? sourceTranslation,
  String? sourceHistoryId,
});

/// Owned by the main engine. Child engines issue commands and display snapshots.
final class ScreenshotTranslationRuntime extends ChangeNotifier {
  static const maxRetryableImageSaveCount = 5;
  static const maxRetryableImageSaveBytes = 32 * 1024 * 1024;

  ScreenshotTranslationRuntime({
    required this.capture,
    this.captureAtBounds,
    required this.recognize,
    this.recognizeDocument,
    required this.translate,
    this.translateWithRoute,
    this.translateDocumentWithRoute,
    this.cancelTranslation,
    this.createResultWindow,
    this.onOpenHistory,
    this.onOpenModels,
    this.onOpenDictionaryLookup,
    this.onAddScreenshotWord,
    this.onLookupDictionary,
    this.translateSelectedWord,
    this.cancelSelectedWordTranslation,
    this.selectedWordTranslationTimeout = const Duration(seconds: 45),
    this.ocrCapabilitiesInspector,
    this.imageStore,
    this.saveScreenshotImages = _defaultSaveScreenshotImages,
    this.pinnedRegion = _noPinnedRegion,
    this.persistPinnedRegion,
  });

  final Future<CapturedData?> Function() capture;
  final Future<CapturedData?> Function(ScreenshotBounds bounds)?
  captureAtBounds;
  final ScreenshotTranslationRecognizer recognize;
  final ScreenshotTranslationDocumentRecognizer? recognizeDocument;
  final ScreenshotTranslationRunner translate;
  final ScreenshotTranslationRouteAwareRunner? translateWithRoute;
  final ScreenshotTranslationDocumentRouteAwareRunner?
  translateDocumentWithRoute;
  final Future<bool> Function()? cancelTranslation;
  final Future<ScreenshotTranslationResultHandle> Function()?
  createResultWindow;
  final Future<void> Function()? onOpenHistory;
  final Future<void> Function()? onOpenModels;
  final ScreenshotDictionaryLookupLauncher? onOpenDictionaryLookup;
  final Future<ScreenshotWordAddStatus> Function(ScreenshotWordRequest)?
  onAddScreenshotWord;
  final Future<DictionaryEntry?> Function(String word)? onLookupDictionary;
  final Future<String> Function(String word, String operationId)?
  translateSelectedWord;
  final Future<bool> Function(String operationId)?
  cancelSelectedWordTranslation;
  final Duration selectedWordTranslationTimeout;
  final ScreenshotTranslationOcrInspector? ocrCapabilitiesInspector;
  final ScreenshotTranslationImageStore? imageStore;
  final bool Function() saveScreenshotImages;
  final ScreenshotBounds? Function() pinnedRegion;
  final Future<bool> Function(ScreenshotBounds? bounds)? persistPinnedRegion;

  static ScreenshotBounds? _noPinnedRegion() => null;

  Future<ScreenshotTranslationOcrCapabilities> inspectOcrCapabilities({
    bool refresh = false,
  }) async {
    final inspector = ocrCapabilitiesInspector;
    if (inspector == null) {
      return const ScreenshotTranslationOcrCapabilities.probeFailed();
    }
    return inspector(refresh: refresh);
  }

  static bool _defaultSaveScreenshotImages() => true;

  ScreenshotTranslationSession? _session;
  ScreenshotTranslationSession? get session => _session;
  String? windowError;
  var _sequence = 0;
  var _historyVersionSequence = 0;
  var _revision = 0;
  var _disposed = false;
  var _shuttingDown = false;
  Future<void>? _captureInFlight;
  Future<void>? _pinnedRegionMutationInFlight;
  ScreenshotTranslationCancellationToken? _ocrCancellationToken;
  Future<void>? _ocrSettled;
  final _shutdownOperation = RetryableSingleFlightOperation();
  Future<void> _translationTail = Future.value();
  Future<String>? _selectedWordTranslationInFlight;
  String? _selectedWordTranslationInFlightOperationId;
  bool _activeScreenshotTranslation = false;
  String? _activeHistoryEntryId;
  String? _activeScreenshotCaptureId;
  Future<void>? _activeTranslationSettled;
  ScreenshotTranslationResultHandle? _window;
  Future<ScreenshotTranslationResultHandle>? _windowInFlight;
  Future<void> _pushTail = Future.value();
  final Map<String, ScreenshotTranslationImageWriteLease> _imageWriteLeases =
      {};
  final Map<String, _ScreenshotImageSnapshot> _retryableImageSaves = {};
  final Set<String> _pendingCaptureImageDeletions = {};
  final Set<Future<void>> _activeImageSaveTasks = {};

  List<ScreenshotTranslationRetryableImageSave> get retryableImageSaves =>
      List.unmodifiable(
        {
          ..._retryableImageSaves.keys,
          if (_activeRetryableSnapshot != null) _session!.id,
        }.map(
          (captureId) =>
              ScreenshotTranslationRetryableImageSave(captureId: captureId),
        ),
      );

  // The active session already owns its pixels. Expose those as retryable
  // without admitting another snapshot into the bounded history cache.
  _ScreenshotImageSnapshot? get _activeRetryableSnapshot {
    final current = _session;
    if (_disposed ||
        _shuttingDown ||
        imageStore == null ||
        current == null ||
        !current.imageSaveAllowed ||
        current.imageBytes == null ||
        !_isRetryableImageStatus(current.imageSaveStatus)) {
      return null;
    }
    return _ScreenshotImageSnapshot(
      bytes: current.imageBytes!,
      allowed: true,
      lease: _imageWriteLeases[current.id],
    );
  }

  static bool _isRetryableImageStatus(
    ScreenshotTranslationImageSaveStatus status,
  ) =>
      status == ScreenshotTranslationImageSaveStatus.failed ||
      status == ScreenshotTranslationImageSaveStatus.cacheLimitReached;

  static bool _hasStoredOrPendingImage(
    ScreenshotTranslationImageSaveStatus status,
  ) =>
      status == ScreenshotTranslationImageSaveStatus.saving ||
      status == ScreenshotTranslationImageSaveStatus.saved ||
      _isRetryableImageStatus(status);

  int get retryableImageSaveCacheCount => _retryableImageSaves.length;

  int get retryableImageSaveCacheBytes => _retryableImageSaves.values.fold(
    0,
    (total, snapshot) => total + snapshot.bytes.lengthInBytes,
  );

  bool _current(String id, [int? revision]) =>
      !_disposed &&
      _session?.id == id &&
      (revision == null || revision == _revision);

  bool _sameSession(String id, int revision) =>
      _session?.id == id && revision == _revision;

  Future<void> startCapture() {
    return _startCapture();
  }

  /// Starts a capture from the workbench with an optional guard around only
  /// the native selection operation. OCR and translation run after the guard
  /// has restored the main window.
  Future<void> startWorkbenchCapture({
    ScreenshotTranslationCaptureGuard? captureGuard,
  }) => _startCapture(captureGuard: captureGuard);

  Future<bool> startPinnedCapture({
    required ScreenshotBounds bounds,
    required String expectedSessionId,
    ScreenshotTranslationCaptureGuard? captureGuard,
  }) async {
    if (_disposed || _shuttingDown) return false;
    while (_pinnedRegionMutationInFlight != null) {
      final pending = _pinnedRegionMutationInFlight;
      if (pending != null) await pending;
    }
    if (_disposed ||
        _shuttingDown ||
        _session?.id != expectedSessionId ||
        _isPinnedRegion(bounds) != true ||
        _captureInFlight != null) {
      return false;
    }
    final selection = Completer<void>();
    _captureInFlight = selection.future;
    unawaited(
      _capture(
        selection,
        _snapshotImageSavePreference(),
        captureGuard,
        fixedBounds: bounds,
      ).catchError((Object error, StackTrace stackTrace) {
        _reportCaptureLaunchFailure(selection, error, stackTrace);
      }),
    );
    return true;
  }

  Future<void> _startCapture({
    ScreenshotTranslationCaptureGuard? captureGuard,
    ScreenshotBounds? fixedBounds,
  }) async {
    if (_disposed || _shuttingDown) return;
    while (_pinnedRegionMutationInFlight != null) {
      final pending = _pinnedRegionMutationInFlight;
      if (pending != null) await pending;
    }
    if (_disposed || _shuttingDown) return;
    // The native selector must never be opened twice by orb/hotkey races.
    final inFlight = _captureInFlight;
    if (inFlight != null) return inFlight;
    final selection = Completer<void>();
    _captureInFlight = selection.future;
    final saveImagesForCapture = _snapshotImageSavePreference();
    await _capture(
      selection,
      saveImagesForCapture,
      captureGuard,
      fixedBounds: fixedBounds,
    );
  }

  bool _snapshotImageSavePreference() {
    try {
      return saveScreenshotImages();
    } catch (_) {
      // Preference access must not prevent the native screenshot workflow.
      return false;
    }
  }

  void _reportCaptureLaunchFailure(
    Completer<void> selection,
    Object error,
    StackTrace stackTrace,
  ) {
    debugPrint('Screenshot capture failed before completion: $error');
    debugPrintStack(stackTrace: stackTrace);
    if (!selection.isCompleted) selection.complete();
    if (identical(_captureInFlight, selection.future)) {
      _captureInFlight = null;
    }
    final session = _session;
    if (!_disposed &&
        session?.status == ScreenshotTranslationStatus.capturing) {
      _session = session!.withState(
        ScreenshotTranslationStatus.failed,
        errorCode: _errorCode(error),
      );
      _notify();
    }
  }

  Future<void> _capture(
    Completer<void> selection,
    bool saveImagesForCapture,
    ScreenshotTranslationCaptureGuard? captureGuard, {
    ScreenshotBounds? fixedBounds,
  }) async {
    CapturedData? pixels;
    final id =
        'screenshot-${DateTime.now().microsecondsSinceEpoch}-${++_sequence}';
    final previousSessionId = _session?.id;
    var previousSession = _session;
    if (previousSessionId != null &&
        !_retryableImageSaves.containsKey(previousSessionId)) {
      _imageWriteLeases.remove(previousSessionId);
    }
    _revision++;
    final store = imageStore;
    if (saveImagesForCapture &&
        store is ScreenshotTranslationCoordinatedImageStore) {
      try {
        _imageWriteLeases[id] = store.beginImageWrite(id);
      } catch (_) {
        // Image persistence must not prevent the screenshot workflow.
      }
    }
    _session = ScreenshotTranslationSession(
      id: id,
      imageSaveAllowed: saveImagesForCapture,
      status: ScreenshotTranslationStatus.capturing,
    );
    _notify();
    try {
      // Cancel before replacing a request so the service cannot persist its late success.
      await _cancelActiveRecognition('开始了新的截图');
      await _cancelActive();
      if (!_current(id)) return;
      await _clearResultWindow(
        isCurrent: () => _current(id),
        reconnectIfSuperseded: true,
      );
      if (!_current(id)) return;
      Future<CapturedData?> captureRequestedRegion() {
        if (fixedBounds == null) return capture();
        final captureFixed = captureAtBounds;
        if (captureFixed == null) {
          throw const ScreenshotTranslationCaptureException(
            '当前平台不支持固定区域截图，请重新框选。',
          );
        }
        return captureFixed(fixedBounds);
      }

      pixels = await (captureGuard == null
          ? captureRequestedRegion()
          : captureGuard(captureRequestedRegion));
      if (!_current(id)) return;
      if (pixels == null) {
        _session = ScreenshotTranslationSession(
          id: id,
          imageSaveAllowed: saveImagesForCapture,
          status: ScreenshotTranslationStatus.cancelled,
        );
        _notify();
        await _clearResultWindow(isCurrent: () => _current(id));
        return;
      }
      final regionContentChanged = await _regionContentChanged(
        previousSession,
        pixels,
      );
      previousSession = null;
      if (!_current(id)) return;
      _session = ScreenshotTranslationSession(
        id: id,
        bounds: pixels.bounds,
        imageBytes: pixels.bytes,
        regionPinned: _isPinnedRegion(pixels.bounds),
        regionContentChanged: regionContentChanged,
        imageSaveAllowed: saveImagesForCapture,
        imageSaveStatus: _initialImageSaveStatus(saveImagesForCapture),
        status: ScreenshotTranslationStatus.recognizing,
      );
      _notify();
      unawaited(_push(id));
      // Selection is over; another screenshot can replace this OCR/translation.
      if (!selection.isCompleted) selection.complete();
      _captureInFlight = null;
      final cancellationToken = ScreenshotTranslationCancellationToken();
      final ocrSettled = Completer<void>();
      _ocrCancellationToken = cancellationToken;
      _ocrSettled = ocrSettled.future;
      late String source;
      ScreenshotTranslationOcrDocument? document;
      try {
        final recognizeStructured = recognizeDocument;
        if (recognizeStructured != null) {
          final recognizedDocument =
              await Future<ScreenshotTranslationOcrDocument>.sync(
                () => recognizeStructured(pixels!, cancellationToken),
              );
          document = recognizedDocument;
          source = recognizedDocument.text.trim();
        } else {
          source = (await Future<String>.sync(
            () => recognize(pixels!, cancellationToken),
          )).trim();
        }
      } finally {
        // Release the method's local screenshot reference only after the OCR
        // adapter has finished its cleanup, even when OCR throws or is cancelled.
        pixels = null;
        if (identical(_ocrCancellationToken, cancellationToken)) {
          _ocrCancellationToken = null;
          _ocrSettled = null;
        }
        if (!ocrSettled.isCompleted) ocrSettled.complete();
      }
      if (!_current(id)) return;
      if (source.length > screenshotTranslationMaxSourceCharacters) {
        throw const ScreenshotTranslationOcrException(
          'ocr_output_limit',
          '识别文本超过单次翻译上限，请缩小选区或分段截图。',
        );
      }
      _session = _session!.withState(
        ScreenshotTranslationStatus.recognizing,
        recognizedText: source,
        ocrLayout: document?.layout,
      );
      if (source.isEmpty) {
        _session = _session!.withState(
          ScreenshotTranslationStatus.empty,
          recognizedText: source,
        );
        _notify();
        await _push(id);
        return;
      }
      await _translate(id, source);
    } catch (error) {
      if (!_current(id)) return;
      _session = _session!.withState(
        ScreenshotTranslationStatus.failed,
        errorCode: _errorCode(error),
      );
      _notify();
      await _push(id);
    } finally {
      pixels = null;
      if (!selection.isCompleted) selection.complete();
      if (identical(_captureInFlight, selection.future)) {
        _captureInFlight = null;
      }
    }
  }

  bool _isPinnedRegion(ScreenshotBounds bounds) {
    try {
      return pinnedRegion() == bounds;
    } catch (_) {
      return false;
    }
  }

  Future<bool?> _regionContentChanged(
    ScreenshotTranslationSession? previous,
    CapturedData current,
  ) async {
    if (previous?.bounds != current.bounds || previous?.imageBytes == null) {
      return null;
    }
    final previousBytes = previous!.imageBytes!;
    final currentBytes = current.bytes;
    return screenshotTranslationImageBytesDiffer(previousBytes, currentBytes);
  }

  ScreenshotTranslationImageSaveStatus _initialImageSaveStatus(bool allowed) {
    if (!allowed) return ScreenshotTranslationImageSaveStatus.notRequested;
    return imageStore == null
        ? ScreenshotTranslationImageSaveStatus.unavailable
        : ScreenshotTranslationImageSaveStatus.notRequested;
  }

  Future<void> retranslate(String editedSource) async {
    await _retranslate(editedSource);
  }

  /// Reuses the current screenshot history row with the opposite of the
  /// currently selected English/Chinese direction.
  Future<void> retranslateInOppositeDirection(String editedSource) async {
    final current = _session;
    if (current == null) return;
    await _retranslate(
      editedSource,
      directionOverride: current.direction.opposite,
    );
  }

  Future<void> _retranslate(
    String editedSource, {
    TranslationDirection? directionOverride,
  }) async {
    final current = _session;
    if (current == null ||
        _disposed ||
        _shuttingDown ||
        current.imageBytes == null) {
      return;
    }
    final source = editedSource.trim();
    final preservedDirection =
        current.directionManuallyOverridden && source == current.recognizedText
        ? current.direction
        : null;
    final retryDirection = directionOverride ?? preservedDirection;
    final revision = ++_revision;
    await _cancelActive();
    if (!_current(current.id, revision)) return;
    await _translate(current.id, source, directionOverride: retryDirection);
  }

  Future<bool> retryImageSave({
    String? historyEntryId,
    String? captureId,
  }) async {
    if (_disposed || _shuttingDown) return false;
    final id = captureId ?? historyEntryId ?? _session?.id;
    if (id == null) return false;
    if (_pendingCaptureImageDeletions.contains(id)) return false;
    final snapshot =
        _retryableImageSaves[id] ??
        (_session?.id == id ? _activeRetryableSnapshot : null);
    if (snapshot == null || !snapshot.allowed || imageStore == null) {
      return false;
    }
    return _startImageSave(id, snapshot);
  }

  /// Releases an image snapshot retained only for an explicit retry.
  void purgeRetryableImageSave(String captureId) {
    _pendingCaptureImageDeletions.remove(captureId);
    _retryableImageSaves.remove(captureId);
    _imageWriteLeases.remove(captureId);
    final current = _session;
    if (current != null &&
        current.id == captureId &&
        _hasStoredOrPendingImage(current.imageSaveStatus)) {
      _session = current.withState(
        current.status,
        translatedText: current.translatedText,
        imageSaveStatus: ScreenshotTranslationImageSaveStatus.invalidated,
      );
      _notify();
    }
  }

  /// Stops work and closes the transient result for a history row being
  /// deleted. Waiting for the matching translation lane to settle ensures a
  /// provider cannot commit the same history ID after the archive removes it.
  Future<void> deleteHistoryEntry(String historyEntryId) async {
    final current = _session;
    final activeEntryMatches = _activeHistoryEntryId == historyEntryId;
    final currentEntryMatches = current?.historyEntryId == historyEntryId;
    if (!activeEntryMatches && !currentEntryMatches) return;

    // A previous translation lane may still be settling after a new capture
    // has replaced its session. Only close the session that owns the target
    // lane; otherwise wait for the old provider write without touching the
    // new screenshot's transient result.
    if (current != null &&
        (currentEntryMatches ||
            (activeEntryMatches && current.id == _activeScreenshotCaptureId))) {
      await _closeCurrentSessionForCapture(current.id, invalidateImage: false);
      return;
    }

    if (activeEntryMatches) {
      final settled = _activeTranslationSettled;
      await _cancelActive();
      if (settled != null) await settled;
    }
  }

  /// Quiesces the live capture while retaining retries until history commits.
  Future<void> prepareCaptureImageDeletion(String captureId) async {
    final current = _session;
    if (current?.id == captureId) {
      // Reject capacity overflow before changing retry permission or closing
      // the session. The Provider must remain active when deletion is blocked.
      _retainCurrentImageForHistoryDeletion(current!);
    }
    _pendingCaptureImageDeletions.add(captureId);
    if (current?.id != captureId) {
      return;
    }
    await _closeCurrentSessionForCapture(captureId, invalidateImage: false);
  }

  /// Reissues permission for retained pixels after history deletion rolls back.
  /// The old snapshot/lease remains invalid for every already-running save.
  void cancelCaptureImageDeletion(String captureId) {
    _pendingCaptureImageDeletions.remove(captureId);
    final snapshot = _retryableImageSaves[captureId];
    final store = imageStore;
    if (snapshot == null ||
        store is! ScreenshotTranslationCoordinatedImageStore) {
      return;
    }
    try {
      final lease = store.beginImageWrite(captureId);
      if (!store.acceptsImageWriteLease(captureId, lease)) return;
      _imageWriteLeases[captureId] = lease;
      _retryableImageSaves[captureId] = _ScreenshotImageSnapshot(
        bytes: snapshot.bytes,
        allowed: snapshot.allowed,
        lease: lease,
      );
    } catch (_) {
      // Keep the retained bytes if a permission refresh is temporarily unavailable.
    }
  }

  Future<void> _closeCurrentSessionForCapture(
    String captureId, {
    required bool invalidateImage,
  }) async {
    if (_session?.id != captureId) return;
    if (!invalidateImage) {
      _retainCurrentImageForHistoryDeletion(_session!);
    }
    final revision = ++_revision;
    _session = null;
    if (invalidateImage) purgeRetryableImageSave(captureId);
    _notify();

    // Capture the current tail before awaiting cancellation. A new session
    // may start while this deletion is in progress and must remain independent.
    final translation = _translationTail;
    await _cancelActive();
    await translation;
    await _pushTail;
    if (_disposed || revision != _revision || _session != null) return;
    await _clearResultWindow(
      isCurrent: () => !_disposed && revision == _revision && _session == null,
    );
  }

  void _retainCurrentImageForHistoryDeletion(
    ScreenshotTranslationSession current,
  ) {
    final bytes = current.imageBytes;
    final store = imageStore;
    if (!current.imageSaveAllowed ||
        bytes == null ||
        store == null ||
        current.imageSaveStatus ==
            ScreenshotTranslationImageSaveStatus.invalidated ||
        current.imageSaveStatus == ScreenshotTranslationImageSaveStatus.saved) {
      return;
    }
    final lease = _imageWriteLeases[current.id];
    if (store is ScreenshotTranslationCoordinatedImageStore) {
      try {
        if (lease == null || !store.acceptsImageWriteLease(current.id, lease)) {
          return;
        }
      } catch (_) {
        return;
      }
    }
    // A provider may have committed text before _translate starts image
    // persistence. Closing the session must retain these permitted pixels for
    // deletion rollback, subject to the same count/byte limits as save retries.
    final snapshot = _ScreenshotImageSnapshot(
      bytes: bytes,
      allowed: current.imageSaveAllowed,
      lease: lease,
    );
    if (!_canRetainRetryableSnapshot(current.id, snapshot)) {
      throw ScreenshotTranslationRetryCacheFullException();
    }
    _retainRetryableSnapshot(current.id, snapshot);
  }

  /// Releases all in-memory image snapshots retained for explicit retries.
  void purgeAllRetryableImageSaves() {
    _pendingCaptureImageDeletions.clear();
    _retryableImageSaves.clear();
    _imageWriteLeases.clear();
    final current = _session;
    if (current != null && _hasStoredOrPendingImage(current.imageSaveStatus)) {
      _session = current.withState(
        current.status,
        translatedText: current.translatedText,
        imageSaveStatus: ScreenshotTranslationImageSaveStatus.invalidated,
      );
      _notify();
    }
  }

  /// Releases image retries invalidated by a completed clear operation.
  ///
  /// Captures started after the clear's linearization point carry a current
  /// write lease and must keep it while they wait for the clear barrier.
  void purgeInvalidatedImageSaves() {
    final store = imageStore;
    if (store is! ScreenshotTranslationCoordinatedImageStore) {
      purgeAllRetryableImageSaves();
      return;
    }

    final invalidatedIds = <String>{};
    for (final entry in _retryableImageSaves.entries) {
      final lease = entry.value.lease;
      if (lease == null || !store.acceptsImageWriteLease(entry.key, lease)) {
        invalidatedIds.add(entry.key);
      }
    }
    for (final entry in _imageWriteLeases.entries) {
      if (!store.acceptsImageWriteLease(entry.key, entry.value)) {
        invalidatedIds.add(entry.key);
      }
    }

    final current = _session;
    final currentLease = current == null ? null : _imageWriteLeases[current.id];
    final currentImageInvalidated =
        current != null &&
        _hasStoredOrPendingImage(current.imageSaveStatus) &&
        (currentLease == null ||
            !store.acceptsImageWriteLease(current.id, currentLease));

    for (final id in invalidatedIds) {
      _pendingCaptureImageDeletions.remove(id);
      _retryableImageSaves.remove(id);
      _imageWriteLeases.remove(id);
    }
    if (currentImageInvalidated) {
      _session = current.withState(
        current.status,
        translatedText: current.translatedText,
        imageSaveStatus: ScreenshotTranslationImageSaveStatus.invalidated,
      );
      _notify();
    }
  }

  Future<void> _translate(
    String id,
    String source, {
    TranslationDirection? directionOverride,
  }) async {
    if (!_current(id)) return;
    if (source.length > screenshotTranslationMaxSourceCharacters) {
      _session = _session!.withState(
        ScreenshotTranslationStatus.failed,
        errorCode: 'ocr_output_limit',
      );
      _notify();
      await _push(id);
      return;
    }
    final revision = _revision;
    final direction =
        directionOverride ??
        detectScreenshotTranslationDirection(
          source,
          fallback: _session!.direction,
        );
    final currentSession = _session!;
    final historyEntryId = currentSession.historyEntryId == null
        ? id
        : '$id-v${++_historyVersionSequence}';
    final imageBytes = currentSession.imageBytes;
    final imageSnapshot = imageBytes == null
        ? null
        : _ScreenshotImageSnapshot(
            bytes: imageBytes,
            allowed: currentSession.imageSaveAllowed,
            lease: _imageWriteLeases[id],
          );
    _session = _session!.withState(
      ScreenshotTranslationStatus.translating,
      recognizedText: source,
      direction: direction,
      directionManuallyOverridden: directionOverride != null,
      clearTranslationRoute: true,
      clearTranslationAlignment: true,
    );
    _notify();
    unawaited(_push(id));
    // Reuse the service's single request lane; stale queued work never starts.
    final previous = _translationTail;
    final done = Completer<void>();
    _translationTail = done.future;
    try {
      await previous;
      if (!_current(id, revision)) return;
      if (source.isEmpty) {
        throw const QuickTranslationException('invalid_input');
      }
      _activeScreenshotTranslation = true;
      _activeHistoryEntryId = historyEntryId;
      _activeScreenshotCaptureId = id;
      _activeTranslationSettled = done.future;
      final String translated;
      List<int>? translatedSourceBlockIndices;
      try {
        final documentRouteAwareRunner = translateDocumentWithRoute;
        final layout = currentSession.ocrLayout;
        if (documentRouteAwareRunner != null &&
            canTranslateScreenshotOcrBlocksWithAlignment(
              layout,
              source: source,
            )) {
          final alignedLayout = layout!;
          final documentTranslation = await documentRouteAwareRunner(
            source,
            alignedLayout,
            direction,
            origin: 'screenshot_translation',
            historyEntryId: historyEntryId,
            screenshotCaptureId: id,
            onRouteSelected: (route) {
              if (!_current(id, revision)) return;
              final active = _session;
              if (active == null ||
                  active.status != ScreenshotTranslationStatus.translating) {
                return;
              }
              _session = active.withState(
                ScreenshotTranslationStatus.translating,
                translationRoute: route,
              );
              _notify();
              unawaited(_push(id));
            },
          );
          translated = documentTranslation.translatedText;
          final candidateIndices =
              documentTranslation.translatedSourceBlockIndices;
          if (candidateIndices != null &&
              pairScreenshotTranslationOverlay(
                    recognizedText: source,
                    translatedText: translated,
                    layout: alignedLayout,
                    translatedSourceBlockIndices: candidateIndices,
                  ) !=
                  null) {
            translatedSourceBlockIndices = List<int>.unmodifiable(
              candidateIndices,
            );
          }
        } else {
          final routeAwareRunner = translateWithRoute;
          translated = routeAwareRunner == null
              ? await translate(
                  source,
                  direction,
                  origin: 'screenshot_translation',
                  historyEntryId: historyEntryId,
                  screenshotCaptureId: id,
                )
              : await routeAwareRunner(
                  source,
                  direction,
                  origin: 'screenshot_translation',
                  historyEntryId: historyEntryId,
                  screenshotCaptureId: id,
                  onRouteSelected: (route) {
                    if (!_current(id, revision)) return;
                    final active = _session;
                    if (active == null ||
                        active.status !=
                            ScreenshotTranslationStatus.translating) {
                      return;
                    }
                    _session = active.withState(
                      ScreenshotTranslationStatus.translating,
                      translationRoute: route,
                    );
                    _notify();
                    unawaited(_push(id));
                  },
                );
        }
      } finally {
        _activeScreenshotTranslation = false;
        if (_activeHistoryEntryId == historyEntryId) {
          _activeHistoryEntryId = null;
          _activeScreenshotCaptureId = null;
          _activeTranslationSettled = null;
        }
      }
      // The provider may have committed text history immediately before
      // shutdown. Keep this active session valid until its image save starts.
      if (!_sameSession(id, revision)) return;
      _session = _session!.withState(
        ScreenshotTranslationStatus.completed,
        translatedText: translated,
        translatedSourceBlockIndices: translatedSourceBlockIndices,
        historyEntryId: historyEntryId,
      );
      if (imageSnapshot != null) await _startImageSave(id, imageSnapshot);
    } catch (error) {
      if (!_current(id, revision)) return;
      _session = _session!.withState(
        ScreenshotTranslationStatus.failed,
        errorCode: _errorCode(error),
      );
    } finally {
      done.complete();
      if (_current(id, revision)) {
        _notify();
        await _push(id);
      }
    }
  }

  Future<bool> _startImageSave(String id, _ScreenshotImageSnapshot snapshot) {
    final finished = Completer<bool>();
    final task = finished.future;
    final activeTask = task.then<void>((_) {});
    _activeImageSaveTasks.add(activeTask);
    unawaited(() async {
      try {
        final saved = await _saveImageSnapshot(id, snapshot);
        if (!finished.isCompleted) finished.complete(saved);
      } catch (_) {
        _recordImageSaveFailure(id, snapshot);
        _notify();
        if (!finished.isCompleted) finished.complete(false);
      } finally {
        _activeImageSaveTasks.remove(activeTask);
      }
    }());
    return task;
  }

  Future<bool> _saveImageSnapshot(
    String id,
    _ScreenshotImageSnapshot snapshot,
  ) async {
    if (!snapshot.allowed) return false;
    final store = imageStore;
    if (store == null) {
      _updateImageSaveStatus(
        id,
        ScreenshotTranslationImageSaveStatus.unavailable,
      );
      return false;
    }

    _updateImageSaveStatus(id, ScreenshotTranslationImageSaveStatus.saving);
    if (_session?.id == id) await _push(id);

    var saved = false;
    var invalidated = false;
    try {
      if (store is ScreenshotTranslationCoordinatedImageStore) {
        final lease = snapshot.lease;
        if (lease == null) {
          invalidated = true;
        } else {
          saved = await store.saveWithLease(id, snapshot.bytes, lease);
          invalidated = !saved;
        }
      } else {
        await store.save(id, snapshot.bytes);
        saved = true;
      }
    } catch (_) {
      // Keep the completed translation and its text history authoritative.
      if (store is ScreenshotTranslationCoordinatedImageStore) {
        final lease = snapshot.lease;
        invalidated = lease == null || !store.acceptsImageWriteLease(id, lease);
      }
    }

    if (saved && store is ScreenshotTranslationCoordinatedImageStore) {
      final lease = snapshot.lease;
      invalidated = lease == null || !store.acceptsImageWriteLease(id, lease);
      if (invalidated) saved = false;
    }

    if (saved) {
      _retryableImageSaves.remove(id);
      if (_session?.id != id) _imageWriteLeases.remove(id);
      _updateImageSaveStatus(id, ScreenshotTranslationImageSaveStatus.saved);
    } else if (invalidated) {
      _discardInvalidatedImageSnapshot(id, snapshot);
      _updateImageSaveStatus(
        id,
        ScreenshotTranslationImageSaveStatus.invalidated,
      );
    } else {
      _recordImageSaveFailure(id, snapshot);
    }
    if (_session?.id == id) await _push(id);
    _notify();
    return saved;
  }

  void _recordImageSaveFailure(String id, _ScreenshotImageSnapshot snapshot) {
    final store = imageStore;
    if (store is ScreenshotTranslationCoordinatedImageStore) {
      final lease = snapshot.lease;
      var accepted = false;
      try {
        accepted = lease != null && store.acceptsImageWriteLease(id, lease);
      } catch (_) {
        // Permission could not be confirmed. Do not retain screenshot bytes
        // from an outer failure callback after deletion/clear has purged them.
      }
      if (!accepted) {
        _discardInvalidatedImageSnapshot(id, snapshot);
        _updateImageSaveStatus(
          id,
          ScreenshotTranslationImageSaveStatus.invalidated,
        );
        return;
      }
    }
    final canRetry = snapshot.allowed && _retainRetryableSnapshot(id, snapshot);
    _updateImageSaveStatus(
      id,
      canRetry
          ? ScreenshotTranslationImageSaveStatus.failed
          : ScreenshotTranslationImageSaveStatus.cacheLimitReached,
    );
  }

  bool _canRetainRetryableSnapshot(
    String id,
    _ScreenshotImageSnapshot snapshot,
  ) {
    final existing = _retryableImageSaves[id];
    final nextCount = _retryableImageSaves.length + (existing == null ? 1 : 0);
    final nextBytes =
        retryableImageSaveCacheBytes -
        (existing?.bytes.lengthInBytes ?? 0) +
        snapshot.bytes.lengthInBytes;
    return nextCount <= maxRetryableImageSaveCount &&
        nextBytes <= maxRetryableImageSaveBytes;
  }

  bool _retainRetryableSnapshot(String id, _ScreenshotImageSnapshot snapshot) {
    if (!_canRetainRetryableSnapshot(id, snapshot)) {
      _retryableImageSaves.remove(id);
      return false;
    }
    _retryableImageSaves[id] = snapshot;
    return true;
  }

  void _discardInvalidatedImageSnapshot(
    String id,
    _ScreenshotImageSnapshot snapshot,
  ) {
    final retained = _retryableImageSaves[id];
    if (retained != null &&
        (_pendingCaptureImageDeletions.contains(id) ||
            !identical(retained, snapshot))) {
      // A pending deletion can roll back, or its rollback has already issued
      // a replacement lease. A late callback must not discard those pixels.
      return;
    }
    _retryableImageSaves.remove(id);
    _imageWriteLeases.remove(id);
  }

  void _updateImageSaveStatus(
    String id,
    ScreenshotTranslationImageSaveStatus status,
  ) {
    final current = _session;
    if (_disposed || current == null || current.id != id) return;
    _session = current.withState(
      current.status,
      translatedText: current.translatedText,
      imageSaveStatus: status,
    );
    _notify();
  }

  Future<void> _cancelActive() async {
    if (!_activeScreenshotTranslation) return;
    try {
      await cancelTranslation?.call();
    } catch (_) {
      /* Next service call reports availability. */
    }
  }

  Future<void> _cancelActiveRecognition(String reason) async {
    final settled = _ocrSettled;
    if (settled == null) return;
    _ocrCancellationToken?.cancel(reason);
    // _capture completes this only after the OCR adapter's cleanup has ended
    // and its local reference to the captured image has been cleared.
    await settled;
  }

  Future<void> _push(String id) {
    return _enqueueResultWindowOperation(() async {
      if (!_current(id) || createResultWindow == null) return;
      ScreenshotTranslationResultHandle? window;
      try {
        window = await _ensureResultWindow();
        if (!_current(id)) return;
        await window.update(_session);
        if (!_current(id)) return;
        if (windowError != null) {
          windowError = null;
          _notify();
        }
      } on ScreenshotTranslationResultHandleSupersededException {
        if (window != null) _discardResultWindow(window);
        ScreenshotTranslationResultHandle? replacement;
        try {
          replacement = await _ensureResultWindow();
          if (!_current(id)) return;
          await replacement.update(_session);
          if (!_current(id)) return;
          if (windowError != null) {
            windowError = null;
            _notify();
          }
        } catch (_) {
          _reportResultWindowConnectionFailure(expectedWindow: replacement);
        }
      } catch (_) {
        _reportResultWindowConnectionFailure(expectedWindow: window);
      }
    });
  }

  /// Serializes a complete result-window operation, including visibility work.
  /// A previous failed operation must not poison all later queue entries.
  Future<void> _enqueueResultWindowOperation(
    Future<void> Function() operation,
  ) {
    final done = _pushTail.then<void>(
      (_) => operation(),
      onError: (Object _, StackTrace _) => operation(),
    );
    _pushTail = done;
    return done;
  }

  Future<ScreenshotTranslationResultHandle> _ensureResultWindow() async {
    final current = _window;
    if (current != null) return current;
    final create = createResultWindow;
    if (create == null) {
      throw StateError('Screenshot result window is not configured');
    }
    final inFlight = _windowInFlight ??= create();
    try {
      final created = await inFlight;
      _window ??= created;
      if (identical(_windowInFlight, inFlight)) _windowInFlight = null;
      return _window!;
    } catch (_) {
      if (identical(_windowInFlight, inFlight)) _windowInFlight = null;
      rethrow;
    }
  }

  void _discardResultWindow(ScreenshotTranslationResultHandle window) {
    if (!identical(_window, window)) return;
    _window = null;
    _windowInFlight = null;
  }

  /// Best-effort result-window cleanup must not turn a screenshot, cancel, or
  /// history deletion into a failed operation when a child engine went stale.
  Future<void> _clearResultWindow({
    required bool Function() isCurrent,
    bool reconnectIfSuperseded = false,
    bool allowDisposed = false,
  }) => _enqueueResultWindowOperation(
    () => _clearResultWindowNow(
      isCurrent: isCurrent,
      reconnectIfSuperseded: reconnectIfSuperseded,
      allowDisposed: allowDisposed,
    ),
  );

  Future<void> _clearResultWindowNow({
    required bool Function() isCurrent,
    required bool reconnectIfSuperseded,
    required bool allowDisposed,
  }) async {
    if ((_disposed && !allowDisposed) || !isCurrent()) return;
    var window = _window;
    if (window == null) return;
    try {
      await window.update(null);
    } on ScreenshotTranslationResultHandleSupersededException {
      _discardResultWindow(window);
      if (!reconnectIfSuperseded ||
          createResultWindow == null ||
          !isCurrent()) {
        return;
      }
      try {
        window = await _ensureResultWindow();
        if ((_disposed && !allowDisposed) ||
            !isCurrent() ||
            !identical(_window, window)) {
          return;
        }
        await window.update(null);
      } on ScreenshotTranslationResultHandleSupersededException {
        final staleWindow = window;
        if (staleWindow != null) _discardResultWindow(staleWindow);
        return;
      } catch (_) {
        final failedWindow = window;
        if (failedWindow != null && identical(_window, failedWindow)) {
          try {
            await failedWindow.hide();
          } catch (_) {
            // The child may already be gone; capture can continue without it.
          }
          if (identical(_window, failedWindow)) {
            _reportResultWindowConnectionFailure(expectedWindow: failedWindow);
          }
        }
        return;
      }
    } catch (_) {
      if (identical(_window, window)) {
        try {
          await window.hide();
        } catch (_) {
          // The child may already be gone; capture can continue without it.
        }
        if (identical(_window, window)) {
          _reportResultWindowConnectionFailure(expectedWindow: window);
        }
      }
      return;
    }
    if ((_disposed && !allowDisposed) ||
        !isCurrent() ||
        !identical(_window, window)) {
      return;
    }
    try {
      await window.hide();
    } catch (_) {
      if (identical(_window, window)) {
        _reportResultWindowConnectionFailure(expectedWindow: window);
      }
    }
  }

  void _reportResultWindowConnectionFailure({
    ScreenshotTranslationResultHandle? expectedWindow,
  }) {
    // Business state/history remains in the main engine and can be reopened.
    if (expectedWindow != null) {
      if (!identical(_window, expectedWindow)) return;
      _discardResultWindow(expectedWindow);
    } else if (_window != null) {
      return;
    }
    windowError = '结果窗口连接失败，请重新截取或从主界面恢复。';
    if (!_disposed) notifyListeners();
  }

  Future<void> reopenResult() async {
    final id = _session?.id;
    if (id != null) await _push(id);
  }

  Future<void> closeResult() async {
    if (_shuttingDown) return;
    final revision = ++_revision;
    final closingId = _session?.id;
    if (closingId != null && !_retryableImageSaves.containsKey(closingId)) {
      _imageWriteLeases.remove(closingId);
    }
    _session = null;
    _notify();
    await _cancelActiveRecognition('结果窗口已关闭');
    await _cancelActive();
    if (_disposed || revision != _revision || _session != null) return;
    await _clearResultWindow(
      isCurrent: () => !_disposed && revision == _revision && _session == null,
    );
  }

  Future<void> openHistory() async {
    await onOpenHistory?.call();
  }

  Future<void> openModels() async {
    await onOpenModels?.call();
  }

  /// Await cleanup before the main engine retires child windows and exits.
  Future<void> shutdown() => _shutdownOperation.run(_shutdown);

  Future<void> _shutdown() async {
    _shuttingDown = true;
    _disposed = true;
    // The native selector encodes on a detached worker and replies to Flutter
    // only after the capture operation completes. Keep the plugin/engine alive
    // until that reply has settled, otherwise shutdown can strand the native
    // response and leave the app's capture lease stuck.
    final captureInFlight = _captureInFlight;
    if (captureInFlight != null) await captureInFlight;
    await _cancelActiveRecognition('截屏翻译正在关闭');
    await _cancelActive();
    // An active translate call may already have persisted text history. Let
    // its continuation register and await the matching image write first.
    await _translationTail;
    await _pushTail;
    while (_activeImageSaveTasks.isNotEmpty) {
      await Future.wait(_activeImageSaveTasks.toList(growable: false));
    }
    _revision++;
    _session = null;
    _imageWriteLeases.clear();
    _retryableImageSaves.clear();
    _pendingCaptureImageDeletions.clear();
    final revision = _revision;
    await _clearResultWindow(
      isCurrent: () => revision == _revision && _session == null,
      allowDisposed: true,
    );
  }

  Future<ScreenshotTranslationWindowMessage?> handleMessage(
    ScreenshotTranslationWindowMessage message,
  ) async {
    switch (message.type) {
      case 'addScreenshotWord':
        return _handleScreenshotWord(message);
      case 'lookupScreenshotWord':
        return _handleScreenshotDictionaryLookup(message);
      case 'translateScreenshotWord':
        return _handleScreenshotWordTranslation(message);
      case 'cancelScreenshotWordTranslation':
        return _handleScreenshotWordTranslationCancellation(message);
      case 'togglePinnedRegionRequested':
        return _handlePinnedRegionRequest(message);
      case 'captureRequested':
        unawaited(startCapture());
      case 'retranslateRequested':
        if (message.payload['sessionId'] == _session?.id &&
            message.payload['source'] is String) {
          final source = message.payload['source'] as String;
          if (message.payload['reverseDirection'] == true) {
            unawaited(retranslateInOppositeDirection(source));
          } else {
            unawaited(retranslate(source));
          }
        }
      case 'resultWindowClosed':
        if (message.payload['sessionId'] == _session?.id) {
          unawaited(closeResult());
        }
      case 'openHistory':
        unawaited(openHistory());
      case 'openModels':
        unawaited(openModels());
      case 'openDictionaryLookup':
        final current = _session;
        await onOpenDictionaryLookup?.call(
          sourceContext: current?.recognizedText.trim().isNotEmpty == true
              ? current!.recognizedText
              : null,
          sourceRecognizedText:
              current?.recognizedText.trim().isNotEmpty == true
              ? current!.recognizedText
              : null,
          sourceTranslation: current?.translatedText?.trim().isNotEmpty == true
              ? current!.translatedText
              : null,
          sourceHistoryId: current?.id.trim().isNotEmpty == true
              ? current!.id
              : null,
        );
    }
    return null;
  }

  Future<ScreenshotTranslationWindowMessage> _handlePinnedRegionRequest(
    ScreenshotTranslationWindowMessage message,
  ) async {
    ScreenshotTranslationWindowMessage reply(Map<String, Object?> payload) =>
        ScreenshotTranslationWindowMessage(
          type: 'ack',
          requestId: message.requestId,
          payload: payload,
        );

    final payload = message.payload;
    final current = _session;
    if (message.type != 'togglePinnedRegionRequested' ||
        payload.length != 2 ||
        !payload.containsKey('sessionId') ||
        !payload.containsKey('pinned') ||
        payload['sessionId'] is! String ||
        payload['pinned'] is! bool ||
        current == null ||
        current.id != payload['sessionId'] ||
        current.bounds == null) {
      return reply(const {'errorCode': 'stale_session'});
    }
    if (current.status == ScreenshotTranslationStatus.capturing ||
        _captureInFlight != null) {
      return reply(const {'errorCode': 'capture_in_progress'});
    }

    final shouldPin = payload['pinned'] as bool;
    final ScreenshotBounds? existing;
    try {
      existing = pinnedRegion();
    } catch (_) {
      return reply(const {'errorCode': 'unavailable'});
    }
    if (!shouldPin && existing != current.bounds) {
      return reply(const {'errorCode': 'stale_region'});
    }
    final persist = persistPinnedRegion;
    if (persist == null) return reply(const {'errorCode': 'unavailable'});
    final saved = await updatePinnedRegionPreference(
      shouldPin ? current.bounds : null,
    );
    if (!saved) return reply(const {'errorCode': 'save_failed'});
    if (_session?.id != current.id) {
      return reply(const {'errorCode': 'stale_session'});
    }
    _session = _session!.withState(
      _session!.status,
      translatedText: _session!.translatedText,
      regionPinned: shouldPin,
    );
    _notify();
    unawaited(_push(current.id));
    return reply({'pinned': shouldPin});
  }

  /// Serializes every fixed-region preference write with fixed-region refresh.
  /// Settings-page changes and result-window pin actions must share this gate.
  Future<bool> updatePinnedRegionPreference(ScreenshotBounds? bounds) async {
    if (_disposed || _shuttingDown) return false;
    final pending = _pinnedRegionMutationInFlight;
    final mutation = Completer<void>();
    _pinnedRegionMutationInFlight = mutation.future;
    try {
      if (pending != null) await pending;
      if (_disposed || _shuttingDown) return false;
      final persist = persistPinnedRegion;
      if (persist == null) return false;
      return await persist(bounds);
    } catch (_) {
      return false;
    } finally {
      if (!mutation.isCompleted) mutation.complete();
      if (identical(_pinnedRegionMutationInFlight, mutation.future)) {
        _pinnedRegionMutationInFlight = null;
      }
    }
  }

  Future<ScreenshotTranslationWindowMessage> _handleScreenshotWord(
    ScreenshotTranslationWindowMessage message,
  ) async {
    ScreenshotTranslationWindowMessage reply(Map<String, Object?> payload) =>
        ScreenshotTranslationWindowMessage(
          type: 'ack',
          requestId: message.requestId,
          payload: payload,
        );
    final ScreenshotWordRequest request;
    try {
      // Revalidate here as payload maps can be mutated after decoding.
      request = ScreenshotWordRequest.fromMessage(message);
    } on FormatException {
      return reply(const {'errorCode': 'invalid_word_request'});
    }
    final current = _session;
    if (_disposed ||
        _shuttingDown ||
        current == null ||
        current.status != ScreenshotTranslationStatus.completed ||
        current.id != request.sessionId ||
        current.historyEntryId != request.historyEntryId ||
        current.recognizedText != request.recognizedText ||
        current.translatedText != request.translatedText) {
      return reply(const {'errorCode': 'stale_session'});
    }
    final selected = request.word.toLowerCase();
    bool containsWord(String text) => RegExp(r"[A-Za-z]+(?:['’\-][A-Za-z]+)*")
        .allMatches(text)
        .any(
          (match) =>
              match.group(0)!.replaceAll('’', "'").toLowerCase() ==
              selected.replaceAll('’', "'"),
        );
    final hasWord = containsWord(current.recognizedText);
    if (!hasWord) return reply(const {'errorCode': 'invalid_word_request'});
    final save = onAddScreenshotWord;
    if (save == null) return reply(const {'errorCode': 'wordbook_unavailable'});
    try {
      final result = await save(request);
      return reply({'status': result.name});
    } catch (_) {
      return reply(const {'errorCode': 'save_failed'});
    }
  }

  Future<ScreenshotTranslationWindowMessage> _handleScreenshotDictionaryLookup(
    ScreenshotTranslationWindowMessage message,
  ) async {
    ScreenshotTranslationWindowMessage reply(Map<String, Object?> payload) =>
        ScreenshotTranslationWindowMessage(
          type: 'ack',
          requestId: message.requestId,
          payload: payload,
        );

    final ScreenshotDictionaryLookupRequest request;
    try {
      request = ScreenshotDictionaryLookupRequest.fromMessage(message);
    } on FormatException {
      return reply(const {'errorCode': 'invalid_word_request'});
    }
    final current = _session;
    if (_disposed ||
        _shuttingDown ||
        current == null ||
        !_dictionaryLookupAvailableForSession(current) ||
        current.id != request.sessionId ||
        current.recognizedText != request.recognizedText) {
      return reply(const {'errorCode': 'stale_session'});
    }
    final foundInSource = dictionaryTermAppearsInText(
      request.word,
      current.recognizedText,
    );
    if (!foundInSource) {
      return reply(const {'errorCode': 'invalid_word_request'});
    }
    final lookup = onLookupDictionary;
    if (lookup == null) {
      return reply(const {'errorCode': 'dictionary_unavailable'});
    }
    try {
      final entry = await lookup(request.word);
      final latest = _session;
      if (_disposed ||
          _shuttingDown ||
          latest == null ||
          latest.id != request.sessionId ||
          !_dictionaryLookupAvailableForSession(latest) ||
          latest.recognizedText != request.recognizedText) {
        return reply(const {'errorCode': 'stale_session'});
      }
      if (entry == null) return reply(const {'errorCode': 'not_found'});
      return reply({
        'entry': {
          'word': entry.word,
          'ipa': entry.ipa,
          'partOfSpeech': entry.partOfSpeech,
          'meanings': entry.meanings,
          'example': entry.example,
          'exampleTranslation': entry.exampleTranslation,
          'qualityStatus': entry.qualityStatus,
          'variants': entry.variants,
          'collocations': entry.collocationCandidates,
          'relations': entry.relationCandidates,
          'examples': entry.exampleCandidates
              .take(5)
              .map(
                (example) => {
                  'englishText': example.englishText,
                  'chineseText': example.chineseText,
                  'reviewStatus': example.reviewStatus,
                },
              )
              .toList(growable: false),
        },
      });
    } catch (_) {
      return reply(const {'errorCode': 'dictionary_lookup_failed'});
    }
  }

  Future<ScreenshotTranslationWindowMessage> _handleScreenshotWordTranslation(
    ScreenshotTranslationWindowMessage message,
  ) async {
    ScreenshotTranslationWindowMessage reply(Map<String, Object?> payload) =>
        ScreenshotTranslationWindowMessage(
          type: 'ack',
          requestId: message.requestId,
          payload: payload,
        );

    final ScreenshotWordTranslationRequest request;
    try {
      request = ScreenshotWordTranslationRequest.fromMessage(message);
    } on FormatException {
      return reply(const {'errorCode': 'invalid_word_request'});
    }
    final current = _session;
    if (_disposed ||
        _shuttingDown ||
        current == null ||
        !_dictionaryLookupAvailableForSession(current) ||
        current.id != request.sessionId ||
        current.recognizedText != request.recognizedText) {
      return reply(const {'errorCode': 'stale_session'});
    }
    if (!dictionaryTermAppearsInText(request.word, current.recognizedText)) {
      return reply(const {'errorCode': 'invalid_word_request'});
    }
    final translateWord = translateSelectedWord;
    if (translateWord == null) {
      return reply(const {'errorCode': 'translation_unavailable'});
    }
    if (_selectedWordTranslationInFlight != null) {
      return reply(const {'errorCode': 'translation_in_progress'});
    }

    final operationId = message.requestId;
    if (operationId.trim().isEmpty) {
      return reply(const {'errorCode': 'invalid_word_request'});
    }
    final underlying = Future<String>.sync(
      () => translateWord(request.word, operationId),
    );
    _selectedWordTranslationInFlight = underlying;
    _selectedWordTranslationInFlightOperationId = operationId;
    unawaited(
      underlying.then<void>(
        (_) {
          if (identical(_selectedWordTranslationInFlight, underlying) &&
              _selectedWordTranslationInFlightOperationId == operationId) {
            _selectedWordTranslationInFlight = null;
            _selectedWordTranslationInFlightOperationId = null;
          }
        },
        onError: (Object _, StackTrace __) {
          if (identical(_selectedWordTranslationInFlight, underlying) &&
              _selectedWordTranslationInFlightOperationId == operationId) {
            _selectedWordTranslationInFlight = null;
            _selectedWordTranslationInFlightOperationId = null;
          }
        },
      ),
    );

    try {
      final translation = await underlying.timeout(
        selectedWordTranslationTimeout,
      );
      final latest = _session;
      if (_disposed ||
          _shuttingDown ||
          latest == null ||
          latest.id != request.sessionId ||
          latest.recognizedText != request.recognizedText) {
        return reply(const {'errorCode': 'stale_session'});
      }
      if (translation.trim().isEmpty || translation.length > 10000) {
        return reply(const {'errorCode': 'empty_translation'});
      }
      return reply({'translation': translation});
    } on TimeoutException {
      var cancellationAccepted = false;
      try {
        cancellationAccepted =
            await cancelSelectedWordTranslation
                ?.call(operationId)
                .timeout(const Duration(seconds: 2)) ??
            false;
      } catch (_) {
        // A timed out cancellation must not keep the result child blocked.
      }
      if (cancellationAccepted &&
          identical(_selectedWordTranslationInFlight, underlying) &&
          _selectedWordTranslationInFlightOperationId == operationId) {
        // The backend accepted cancellation for this exact operation ID.
        // Its own translation queue still serializes any later request.
        _selectedWordTranslationInFlight = null;
        _selectedWordTranslationInFlightOperationId = null;
      }
      return reply({
        'errorCode': cancellationAccepted
            ? 'translation_cancelled'
            : 'translation_timeout',
      });
    } on QuickTranslationException catch (error) {
      final code = switch (error.code) {
        'no_remote_provider' ||
        'ambiguous_translation_provider' ||
        'missing_credential' ||
        'local_core_unavailable' ||
        'local_core_error' => 'translation_unavailable',
        _ => 'word_translation_failed',
      };
      return reply({'errorCode': code});
    } catch (_) {
      return reply(const {'errorCode': 'word_translation_failed'});
    }
  }

  Future<ScreenshotTranslationWindowMessage>
  _handleScreenshotWordTranslationCancellation(
    ScreenshotTranslationWindowMessage message,
  ) async {
    ScreenshotTranslationWindowMessage reply(bool cancelled) =>
        ScreenshotTranslationWindowMessage(
          type: 'ack',
          requestId: message.requestId,
          payload: {'cancelled': cancelled},
        );

    final payload = message.payload;
    final rawOperationId = payload['operationId'];
    if (payload.length != 1 ||
        !payload.containsKey('operationId') ||
        rawOperationId is! String ||
        rawOperationId.trim().isEmpty) {
      return reply(false);
    }
    final operationId = rawOperationId.trim();
    if (_selectedWordTranslationInFlight == null ||
        _selectedWordTranslationInFlightOperationId != operationId) {
      return reply(false);
    }
    final cancel = cancelSelectedWordTranslation;
    if (cancel == null) return reply(false);
    var cancelled = false;
    try {
      cancelled = await cancel(operationId);
    } catch (_) {
      cancelled = false;
    }
    if (cancelled &&
        _selectedWordTranslationInFlightOperationId == operationId) {
      _selectedWordTranslationInFlight = null;
      _selectedWordTranslationInFlightOperationId = null;
    }
    return reply(cancelled);
  }

  bool _dictionaryLookupAvailableForSession(
    ScreenshotTranslationSession session,
  ) =>
      session.recognizedText.trim().isNotEmpty &&
      session.status != ScreenshotTranslationStatus.capturing &&
      session.status != ScreenshotTranslationStatus.recognizing &&
      session.status != ScreenshotTranslationStatus.translating;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  static String _errorCode(Object error) => switch (error) {
    QuickTranslationException() => error.code,
    ScreenshotTranslationOcrException() => error.code,
    ScreenshotTranslationCaptureException(code: final code) => code,
    ScreenshotException(code: 'invalid_region_bounds') => 'region_invalid',
    ScreenshotException() => 'capture_failed',
    _ => 'unknown_error',
  };

  @override
  void dispose() {
    unawaited(shutdown().catchError((Object _) {}));
    super.dispose();
  }
}

abstract interface class ScreenshotGlobalHotKey {
  Future<void> register(ScreenshotHotKey key, VoidCallback onPressed);
  Future<void> unregister();
}

final class ScreenshotHotKeyRegistrationException implements Exception {
  const ScreenshotHotKeyRegistrationException(this.code, [this.nativeCode]);
  final String code;
  final int? nativeCode;
}

abstract interface class ScreenshotOrbHandle {
  Future<void> open(ScreenshotOrbPosition? position);
  Future<void> close();
}

/// Optional window visibility controls used while the desktop snapshot is
/// captured, so a layered orb cannot appear inside its own screenshot.
abstract interface class ScreenshotOrbCaptureVisibility {
  Future<void> hideForCapture();
  Future<void> restoreAfterCapture();
}

/// Main engine's serialized desktop lifecycle. Children cannot own hotkeys,
/// preference files, OCR, translation, or app exit policy.
enum ScreenshotOrbRuntimeState {
  initializing,
  starting,
  visible,
  closing,
  disabled,
  failed,
}

final class ScreenshotTranslationDesktopController extends ChangeNotifier {
  ScreenshotTranslationDesktopController({
    required this.store,
    required this.hotKeys,
    required this.createOrb,
    required this.onCapture,
    required this.onOpenMain,
    required this.onOpenSettings,
    required this.onHideMain,
    required this.onReleaseSession,
    required this.onCloseChildren,
    required this.onExit,
    this.onRequestHostExit,
    this.onExitFailure,
  });
  final ScreenshotTranslationPreferencesStore store;
  final ScreenshotGlobalHotKey hotKeys;
  final Future<ScreenshotOrbHandle> Function() createOrb;
  final Future<void> Function() onCapture,
      onOpenMain,
      onOpenSettings,
      onHideMain,
      onReleaseSession,
      onCloseChildren,
      onExit;
  final Future<void> Function()? onRequestHostExit;
  final Future<void> Function()? onExitFailure;
  ScreenshotTranslationPreferences preferences =
      const ScreenshotTranslationPreferences();
  bool _imagePreferencesLoaded = false;
  bool get imagePersistenceEnabled =>
      !_closed && _imagePreferencesLoaded && preferences.saveScreenshotImages;
  ScreenshotOrbRuntimeState orbRuntimeState =
      ScreenshotOrbRuntimeState.initializing;
  bool hotKeyRegistered = false;
  bool hotKeyRecording = false;
  bool exitFailed = false, exitInProgress = false;
  ScreenshotHotKey? _registeredKey;
  String? hotKeyError, orbError, saveError, lifecycleError;
  ScreenshotOrbHandle? _orb;
  Future<void> _tail = Future.value();
  Future<void>? _initialization, _stopping, _quitting;
  bool _closed = false, _notifierDisposed = false;
  void _notify() {
    if (!_notifierDisposed) notifyListeners();
  }

  void reportHostFailure() {
    lifecycleError = '截屏翻译后台初始化失败，请重启译学。';
    _notify();
  }

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final future = _tail.then((_) => operation());
    _tail = future.then((_) {}, onError: (Object _, StackTrace _) {});
    return future;
  }

  Future<void> initialize() => _initialization ??= _serialize(() async {
    if (_closed) return;
    try {
      preferences = await store.read();
    } catch (_) {
      preferences = const ScreenshotTranslationPreferences(
        saveScreenshotImages: false,
      );
    }
    _imagePreferencesLoaded = true;
    _notify();
    if (_closed) return;
    await _register();
    await _syncOrb();
    _notify();
  });

  /// Updates ordinary screenshot preferences while preserving the latest
  /// fixed-region value. Region changes must use [setPinnedRegion] so they
  /// share the runtime capture barrier.
  Future<bool> update(ScreenshotTranslationPreferences next) => _serialize(() {
    final pinnedRegion = preferences.pinnedRegion;
    return _update(
      next.copyWith(
        pinnedRegion: pinnedRegion,
        clearPinnedRegion: pinnedRegion == null,
      ),
    );
  });
  Future<bool> _update(ScreenshotTranslationPreferences next) async {
    if (_closed) return false;
    final old = preferences;
    final hotKeyChanged = old.hotKey != next.hotKey;
    if (hotKeyChanged && hotKeyRecording) {
      hotKeyError = '请先结束快捷键录制，再保存新的快捷键。';
      _notify();
      return false;
    }
    if (hotKeyChanged &&
        !await _switchHotKey(next.hotKey, restoreOnFailure: old.hotKey)) {
      _notify();
      return false;
    }
    if (old.orbEnabled && !next.orbEnabled) {
      // Never remove the user's remaining desktop entry before the main host
      // has successfully restored. A failure must not commit disabled state.
      try {
        await onOpenMain();
        lifecycleError = null;
      } catch (_) {
        lifecycleError = '主窗口恢复失败，已保留悬浮圆球和上次设置。';
        if (hotKeyChanged) await _switchHotKey(old.hotKey);
        _notify();
        return false;
      }
      if (_closed) {
        if (hotKeyChanged) await _switchHotKey(old.hotKey);
        return false;
      }
    }
    try {
      await store.write(next);
    } catch (_) {
      saveError = '设置保存失败，已保留上次有效设置。';
      if (hotKeyChanged) await _switchHotKey(old.hotKey);
      _notify();
      return false;
    }
    if (_closed) {
      if (hotKeyChanged) await _switchHotKey(old.hotKey);
      return false;
    }
    preferences = next;
    saveError = null;
    if (old.orbEnabled != next.orbEnabled) {
      lifecycleError = null;
      await _syncOrb();
    } else if (next.orbEnabled && _orb == null) {
      await _syncOrb();
    }
    _notify();
    return true;
  }

  Future<bool> saveOrbPosition(ScreenshotOrbPosition value) =>
      _serialize(() => _update(preferences.copyWith(orbPosition: value)));
  Future<bool> setPinnedRegion(ScreenshotBounds? bounds) => _serialize(
    () => _update(
      preferences.copyWith(
        pinnedRegion: bounds,
        clearPinnedRegion: bounds == null,
      ),
    ),
  );
  Future<bool> beginHotKeyRecording() => _serialize(() async {
    if (_closed) return false;
    hotKeyRegistered = false;
    hotKeyRecording = true;
    hotKeyError = null;
    _notify();
    try {
      if (_registeredKey != null) await hotKeys.unregister();
      _registeredKey = null;
      _notify();
      return true;
    } catch (_) {
      hotKeyRecording = false;
      hotKeyError = '无法暂停当前快捷键，请重试或重启译学。';
      _notify();
      return false;
    }
  });
  Future<void> endHotKeyRecording() => _serialize(() async {
    if (!hotKeyRecording) return;
    hotKeyRecording = false;
    if (!_closed) await _register();
    _notify();
  });
  Future<void> retryHotKey() => _serialize(() async {
    if (!_closed && !hotKeyRecording) {
      await _register();
      _notify();
    }
  });
  Future<void> retryOrb() => _serialize(() async {
    if (!_closed) {
      await _syncOrb();
      _notify();
    }
  });
  Future<void> _register() async {
    if (_registeredKey != null) {
      try {
        await hotKeys.unregister();
        _registeredKey = null;
      } catch (_) {
        hotKeyRegistered = false;
        hotKeyError = '旧快捷键注销失败，请重试或重启译学。';
        return;
      }
    }
    hotKeyRegistered = false;
    hotKeyError = null;
    try {
      await _registerKey(preferences.hotKey);
    } catch (error) {
      hotKeyError = _hotKeyRegistrationMessage(error);
    }
  }

  Future<void> _registerKey(ScreenshotHotKey key) async {
    await hotKeys.register(key, () {
      if (!_closed &&
          !hotKeyRecording &&
          hotKeyRegistered &&
          _registeredKey == key &&
          preferences.hotKey == key) {
        unawaited(
          onCapture().catchError((Object error, StackTrace stackTrace) {
            debugPrint('Screenshot hotkey capture failed: $error');
            debugPrintStack(stackTrace: stackTrace);
          }),
        );
      }
    });
    _registeredKey = key;
    hotKeyRegistered = true;
    hotKeyError = null;
  }

  Future<bool> _switchHotKey(
    ScreenshotHotKey target, {
    ScreenshotHotKey? restoreOnFailure,
  }) async {
    if (_registeredKey != null) {
      try {
        await hotKeys.unregister();
      } catch (_) {
        hotKeyRegistered = false;
        hotKeyError = '旧快捷键注销失败，请重试或重启译学。';
        return false;
      }
      _registeredKey = null;
    }
    hotKeyRegistered = false;
    try {
      await _registerKey(target);
      return true;
    } catch (error) {
      final targetError = _hotKeyRegistrationMessage(error);
      hotKeyError = targetError;
      if (restoreOnFailure == null) {
        _registeredKey = null;
        hotKeyRegistered = false;
        hotKeyError = '$targetError 旧快捷键恢复失败，请重试或重启译学。';
        return false;
      }
      try {
        await _registerKey(restoreOnFailure);
        hotKeyError = targetError;
      } catch (_) {
        _registeredKey = null;
        hotKeyRegistered = false;
        hotKeyError = '$targetError 旧快捷键恢复失败，请重试或重启译学。';
      }
      return false;
    }
  }

  String _hotKeyRegistrationMessage(Object error) => switch (error) {
    ScreenshotHotKeyRegistrationException(nativeCode: 1409) =>
      '快捷键已被其他应用占用，请修改快捷键。',
    ScreenshotHotKeyRegistrationException(code: 'hotkey_conflict') =>
      '快捷键已被其他应用占用，请修改快捷键。',
    _ => '系统快捷键注册失败，请修改快捷键或重试。',
  };

  Future<void> _syncOrb() async {
    orbRuntimeState = preferences.orbEnabled
        ? ScreenshotOrbRuntimeState.starting
        : ScreenshotOrbRuntimeState.closing;
    orbError = null;
    _notify();
    try {
      if (preferences.orbEnabled) {
        _orb ??= await createOrb();
        await _orb!.open(preferences.orbPosition);
        orbRuntimeState = ScreenshotOrbRuntimeState.visible;
      } else {
        await _orb?.close();
        _orb = null;
        orbRuntimeState = ScreenshotOrbRuntimeState.disabled;
      }
      orbError = null;
    } catch (_) {
      if (preferences.orbEnabled) {
        final failedOrb = _orb;
        _orb = null;
        try {
          await failedOrb?.close();
        } catch (_) {
          // The child deadline already fails closed; retry must create a new
          // child rather than reusing a handle that missed activation.
        }
      }
      orbRuntimeState = ScreenshotOrbRuntimeState.failed;
      orbError = preferences.orbEnabled ? '悬浮球启动失败，请重试。' : '悬浮球关闭失败，请重试。';
    }
    _notify();
  }

  Future<void> openMain() => onOpenMain();

  /// Temporarily removes the main window while the native desktop snapshot is
  /// taken. It also hides a layered orb that would otherwise be included by
  /// CAPTUREBLT, then restores both windows if capture is cancelled or fails.
  Future<T> captureWithMainHidden<T>(
    Future<T> Function() capture, {
    Future<void> Function()? restoreMain,
  }) async {
    return captureWithOrbHidden(() async {
      try {
        await onHideMain();
        return await capture();
      } finally {
        if (restoreMain == null) {
          await onOpenMain();
        } else {
          await restoreMain();
        }
      }
    });
  }

  /// Hides only the native orb during the screen snapshot. Hotkey and orb
  /// captures use this to leave the original foreground app in place.
  Future<T> captureWithOrbHidden<T>(Future<T> Function() capture) async {
    final orb = _orb;
    final ScreenshotOrbCaptureVisibility? visibility =
        orb is ScreenshotOrbCaptureVisibility
        ? orb as ScreenshotOrbCaptureVisibility
        : null;
    var hidden = false;
    try {
      if (visibility != null && preferences.orbEnabled) {
        hidden = true;
        await visibility.hideForCapture();
      }
      return await capture();
    } finally {
      if (hidden &&
          visibility != null &&
          identical(_orb, orb) &&
          !_closed &&
          preferences.orbEnabled) {
        await visibility.restoreAfterCapture();
      }
    }
  }

  Future<void> handleMessage(ScreenshotTranslationWindowMessage message) async {
    if (_closed) return;
    switch (message.type) {
      case 'openMain':
        await openMain();
      case 'openScreenshotSettings':
        await onOpenSettings();
      case 'disableOrb':
        if (preferences.orbEnabled) {
          await update(preferences.copyWith(orbEnabled: false));
        }
      case 'quitRequested':
        final requestHostExit = onRequestHostExit;
        if (requestHostExit == null) {
          unawaited(quit());
        } else {
          try {
            await requestHostExit();
          } catch (error) {
            lifecycleError = '退出请求未能送达主窗口：$error';
            _notify();
          }
        }
      case 'orbMoved':
        final x = message.payload['x'], y = message.payload['y'];
        if (x is num && y is num && x.isFinite && y.isFinite) {
          await saveOrbPosition(
            ScreenshotOrbPosition(x.toDouble(), y.toDouble()),
          );
        }
    }
  }

  Future<void> handleMainClose() async {
    if (exitFailed) {
      await quit();
      return;
    }
    await initialize();
    if (hotKeyRecording) await endHotKeyRecording();
    await _tail;
    if (_closed) return;
    if (preferences.orbEnabled) {
      if (_orb != null && orbError == null) {
        await onHideMain();
      } else {
        await onOpenMain();
        lifecycleError = '圆球暂不可用，主窗口已保留。请重试圆球或在设置中关闭它。';
        _notify();
      }
    } else {
      await quit();
    }
  }

  Future<void> shutdown() {
    final current = _stopping;
    if (current != null) return current;
    late final Future<void> attempt;
    attempt = () async {
      try {
        await _stop();
      } catch (_) {
        // A failed cleanup must be retryable from the exit recovery action.
        if (identical(_stopping, attempt)) _stopping = null;
        rethrow;
      }
    }();
    _stopping = attempt;
    return attempt;
  }

  Future<void> _stop() async {
    _closed = true;
    await _tail;
    Object? firstError;
    for (final action in <Future<void> Function()>[
      () async {
        if (_registeredKey != null) await hotKeys.unregister();
        _registeredKey = null;
        hotKeyRegistered = false;
      },
      onReleaseSession,
      () async {
        await _orb?.close();
        _orb = null;
      },
      onCloseChildren,
    ]) {
      try {
        await action();
      } catch (error) {
        firstError ??= error;
      }
    }
    if (firstError != null) {
      lifecycleError = '退出清理失败，请重试退出。';
      _notify();
      throw StateError('Screenshot desktop cleanup failed');
    }
  }

  Future<void> quit() => _quitting ??= _quit();
  Future<void> _quit() async {
    exitInProgress = true;
    _notify();
    try {
      await shutdown();
    } catch (_) {
      // Cleanup already attempts every step. The session cannot be restored
      // after release, so an explicit quit must still reach the host exit.
    }
    try {
      await onExit();
      exitFailed = false;
    } catch (_) {
      exitFailed = true;
      lifecycleError = '退出未完成，请重试退出。';
      _notify();
      try {
        await onExitFailure?.call();
      } catch (_) {
        lifecycleError = '退出未完成，重试界面显示失败；请再次关闭窗口。';
      }
    } finally {
      exitInProgress = false;
      if (exitFailed) _quitting = null;
      _notify();
    }
  }

  @override
  void dispose() {
    _notifierDisposed = true;
    unawaited(shutdown().catchError((Object _) {}));
    super.dispose();
  }
}
