import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_screenshot/screenshot.dart';
import 'package:yixue_app/core/dictionary_service.dart';
import 'package:yixue_app/core/native_core_bridge.dart';
import 'package:yixue_app/core/screenshot_dictionary_lookup_history.dart';
import 'package:yixue_app/core/screenshot_translation_capture_service.dart';
import 'package:yixue_app/core/screenshot_translation_image_store.dart';
import 'package:yixue_app/core/screenshot_translation_preferences.dart';
import 'package:yixue_app/features/screenshot_translation/screenshot_translation_archive_controller.dart';
import 'package:yixue_app/features/screenshot_translation/screenshot_translation_runtime.dart';
import 'package:yixue_app/features/screenshot_translation/screenshot_translation_workspace.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'history preview reads PNG size from the header without decoding it',
    () {
      final pngHeader = Uint8List(24);
      final header = ByteData.sublistView(pngHeader);
      header.setUint32(0, 0x89504E47, Endian.big);
      header.setUint32(12, 0x49484452, Endian.big);
      header.setUint32(16, 1080, Endian.big);
      header.setUint32(20, 1920, Endian.big);

      expect(screenshotTranslationPngSize(pngHeader), const Size(1080, 1920));
      expect(screenshotTranslationPngSize(Uint8List(24)), isNull);
    },
  );

  testWidgets('cache overflow current image remains retryable from workbench', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1500, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final core = _ArchiveCore();
    final store = _MemoryImageStore();
    var captureSequence = 0;
    final runtime = ScreenshotTranslationRuntime(
      capture: () async {
        final left = captureSequence++;
        return CapturedData(width: 1, height: 1, bytes: _testPng, left: left);
      },
      recognize: (_, [_]) async => 'active source',
      translate:
          (
            source,
            direction, {
            required origin,
            required historyEntryId,
            required screenshotCaptureId,
          }) async {
            core.history.insert(0, _entry(historyEntryId, source: source));
            return '译文';
          },
      imageStore: store,
    );
    for (
      var i = 0;
      i <= ScreenshotTranslationRuntime.maxRetryableImageSaveCount;
      i++
    ) {
      store.failNextSave = true;
      await runtime.startCapture();
    }
    final id = runtime.session!.id;
    final archive = _archive(core, store);
    await tester.pumpWidget(_host(runtime: runtime, archive: archive));
    await _pumpFrames(tester);
    expect(find.textContaining('当前结果仍可重试'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('screenshot-workbench-retry-current-image')),
      findsOneWidget,
    );
    expect(
      find.byKey(ValueKey('screenshot-workbench-retry-image-$id')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('screenshot-workbench-retry-current-image')),
    );
    await _pumpFrames(tester);
    expect(store.images[id], _testPng);
    expect(
      runtime.session!.imageSaveStatus,
      ScreenshotTranslationImageSaveStatus.saved,
    );
    expect(
      runtime.retryableImageSaveCacheCount,
      ScreenshotTranslationRuntime.maxRetryableImageSaveCount,
    );
    expect(tester.takeException(), isNull);
    await _dispose(tester, runtime, archive);
  });

  testWidgets(
    'failed deletion of memory-only image reports uncertainty and permits delete retry',
    (tester) async {
      tester.view.physicalSize = const Size(1500, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final core = _ArchiveCore();
      final store = _MemoryImageStore()..failNextSave = true;
      final runtime = ScreenshotTranslationRuntime(
        capture: () async =>
            CapturedData(width: 1, height: 1, bytes: _testPng, left: 0),
        recognize: (_, [_]) async => 'memory-only source',
        translate:
            (
              source,
              direction, {
              required origin,
              required historyEntryId,
              required screenshotCaptureId,
            }) async {
              core.history.add(_entry(historyEntryId, source: source));
              return '译文';
            },
        imageStore: store,
      );
      await runtime.startCapture();
      final id = runtime.session!.id;
      expect(store.images, isEmpty);
      expect(runtime.retryableImageSaves.single.historyEntryId, id);
      final archive = ScreenshotTranslationArchiveController(
        coreFactory: () => core,
        imageStore: store,
        purgeRetryableImageSave: runtime.purgeRetryableImageSave,
        purgeInvalidatedImageSaves: runtime.purgeInvalidatedImageSaves,
      );
      store.failDelete = true;
      await tester.pumpWidget(_host(runtime: runtime, archive: archive));
      await _pumpFrames(tester);
      await tester.tap(
        find.byKey(const ValueKey('screenshot-workbench-delete-entry')),
      );
      await _pumpFrames(tester);
      await tester.tap(find.text('删除历史并清理无引用原图'));
      await _pumpFrames(tester);
      expect(runtime.retryableImageSaves.single.captureId, id);
      expect(
        runtime.session!.imageSaveStatus,
        ScreenshotTranslationImageSaveStatus.failed,
      );
      expect(core.history.single.id, id);
      expect(core.deletedIds, isEmpty);
      expect(find.text('原图删除未完成，磁盘原图状态未确认；文字历史未删除。请重试删除。'), findsOneWidget);
      expect(find.textContaining('原图和文字历史均已保留'), findsNothing);
      expect(
        find.byKey(ValueKey('screenshot-workbench-retry-image-$id')),
        findsOneWidget,
      );
      store.failDelete = false;
      await tester.tap(
        find.byKey(const ValueKey('screenshot-workbench-delete-entry')),
      );
      await _pumpFrames(tester);
      await tester.tap(find.text('删除历史并清理无引用原图'));
      await _pumpFrames(tester);
      expect(core.history, isEmpty);
      expect(tester.takeException(), isNull);
      await _dispose(tester, runtime, archive);
    },
  );

  testWidgets('first-use state explains how to start and has no blank page', (
    tester,
  ) async {
    final core = _ArchiveCore();
    final store = _MemoryImageStore();
    final archive = _archive(core, store);
    final runtime = _runtime();
    await tester.pumpWidget(_host(runtime: runtime, archive: archive));
    await _pumpFrames(tester);

    expect(find.text('还没有截屏翻译'), findsOneWidget);
    expect(find.text('框选屏幕上的文字后，原图、OCR 原文和译文会归档在这里。'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('screenshot-workbench-empty-capture')),
      findsOneWidget,
    );
    expect(find.text('截屏历史'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await _dispose(tester, runtime, archive);
  });

  testWidgets('image storage scan waits until screenshot settings are opened', (
    tester,
  ) async {
    final store = _MemoryImageStore();
    final archive = _archive(_ArchiveCore(), store);
    final runtime = _runtime();
    await tester.pumpWidget(_host(runtime: runtime, archive: archive));
    await _pumpFrames(tester);

    expect(store.inspectCalls, 0);
    await tester.tap(
      find.byKey(const ValueKey('screenshot-workbench-toggle-settings')),
    );
    await _pumpFrames(tester);
    expect(store.inspectCalls, 1);

    await tester.tap(
      find.byKey(const ValueKey('screenshot-workbench-toggle-settings')),
    );
    await _pumpFrames(tester);
    await tester.tap(
      find.byKey(const ValueKey('screenshot-workbench-toggle-settings')),
    );
    await _pumpFrames(tester);
    expect(store.inspectCalls, 1);
    expect(tester.takeException(), isNull);

    await _dispose(tester, runtime, archive);
  });

  testWidgets('OCR status checks lazily and can be refreshed from settings', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(680, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var inspections = 0;
    final runtime = ScreenshotTranslationRuntime(
      capture: () async => null,
      recognize: (_, [_]) async => '',
      translate: (
        source,
        direction, {
        required origin,
        required historyEntryId,
        required screenshotCaptureId,
      }) async => '译文',
      ocrCapabilitiesInspector: ({bool refresh = false}) async {
        inspections++;
        return const ScreenshotTranslationOcrCapabilities(
          engineAvailable: true,
          availableLanguages: {'eng', 'osd'},
        );
      },
    );
    final archive = _archive(_ArchiveCore(), _MemoryImageStore());
    final desktop = _desktopController();
    await desktop.initialize();
    await tester.pumpWidget(
      _host(runtime: runtime, archive: archive, desktop: desktop),
    );
    await _pumpFrames(tester);

    expect(inspections, 0);
    expect(find.text('本机 OCR 语言与状态'), findsNothing);
    await tester.tap(
      find.byKey(const ValueKey('screenshot-workbench-toggle-settings')),
    );
    await _pumpFrames(tester);

    expect(inspections, 1);
    expect(find.text('OCR 语言包缺少简体中文（chi_sim）'), findsOneWidget);
    expect(
      find.text('请为当前 Tesseract 安装英语（eng）和简体中文（chi_sim）语言包。'),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('screenshot-workbench-refresh-ocr-status')),
    );
    await _pumpFrames(tester);
    expect(inspections, 2);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await runtime.shutdown();
    runtime.dispose();
    archive.dispose();
    await desktop.quit();
    desktop.dispose();
  });

  testWidgets('main capture action starts the runtime capture flow', (
    tester,
  ) async {
    var captures = 0;
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
    );
    final archive = _archive(_ArchiveCore(), _MemoryImageStore());
    await tester.pumpWidget(_host(runtime: runtime, archive: archive));
    await _pumpFrames(tester);

    await tester.tap(
      find.byKey(const ValueKey('screenshot-workbench-capture')),
    );
    await _pumpFrames(tester);
    expect(captures, 1);
    expect(tester.takeException(), isNull);

    await _dispose(tester, runtime, archive);
  });

  testWidgets(
    'history selection shows original image, OCR text, and translation',
    (tester) async {
      tester.view.physicalSize = const Size(3000, 1800);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final png = _testPng;
      final entry = _entry('shot-1', source: 'Hello world');
      final core = _ArchiveCore()..history.add(entry);
      final store = _MemoryImageStore()..images['shot-1'] = png;
      final archive = _archive(core, store);
      final runtime = _runtime();
      await tester.pumpWidget(_host(runtime: runtime, archive: archive));
      await _pumpFrames(tester);

      expect(
        find.byKey(const ValueKey('screenshot-history-row-shot-1')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('screenshot-workbench-image-preview')),
          matching: find.text('本地原图'),
        ),
        findsOneWidget,
      );
      final thumbnail = tester.widget<Image>(
        find.descendant(
          of: find.byKey(const ValueKey('screenshot-workbench-image-preview')),
          matching: find.byType(Image),
        ),
      );
      final thumbnailProvider = thumbnail.image as ResizeImage;
      expect(thumbnailProvider.width, (thumbnail.width! * 2).round());
      expect(thumbnailProvider.height, (thumbnail.height! * 2).round());
      expect(thumbnail.height, lessThanOrEqualTo(260));
      expect(
        find.byKey(const ValueKey('screenshot-workbench-ocr-text')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<SelectableText>(
              find.byKey(const ValueKey('screenshot-workbench-ocr-text')),
            )
            .data,
        'Hello world',
      );
      expect(
        tester
            .widget<SelectableText>(
              find.byKey(
                const ValueKey('screenshot-workbench-translation-text'),
              ),
            )
            .data,
        '你好，世界',
      );
      expect(tester.takeException(), isNull);

      await _dispose(tester, runtime, archive);
    },
  );

  testWidgets(
    'history pairs explicit source and translation paragraphs without moving the screenshot',
    (tester) async {
      tester.view.physicalSize = const Size(3000, 1800);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final entry = _entry(
        'shot-paragraphs',
        source: 'First source paragraph.\n\nSecond source paragraph.',
        translated: '第一段译文。\n\n第二段译文。',
      );
      final core = _ArchiveCore()..history.add(entry);
      final archive = _archive(
        core,
        _MemoryImageStore()..images[entry.id] = _testPng,
      );
      final runtime = _runtime();
      await tester.pumpWidget(_host(runtime: runtime, archive: archive));
      await _pumpFrames(tester);

      expect(
        find.byKey(const ValueKey('screenshot-workbench-image-preview')),
        findsOneWidget,
      );
      expect(find.text('段落对照 · 按文本换行分组，不代表原图坐标对齐'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('screenshot-workbench-aligned-block-0')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('screenshot-workbench-aligned-block-1')),
        findsOneWidget,
      );
      expect(find.text('First source paragraph.'), findsOneWidget);
      expect(find.text('第一段译文。'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await _dispose(tester, runtime, archive);
    },
  );

  testWidgets('history restores OCR position overlay from persisted metadata', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(3000, 1800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final entry = _entry(
      'shot-aligned',
      source: 'Hello world',
      translated: '你好，世界',
      screenshotOcrLayout: {
        'version': 1,
        'coordinateSpace': 'image_pixels',
        'imageWidth': 1,
        'imageHeight': 1,
        'sourceText': 'Hello world',
        'blocks': [
          {'text': 'Hello world', 'left': 0, 'top': 0, 'width': 1, 'height': 1},
        ],
      },
      translatedSourceBlockIndices: const [0],
    );
    final archive = _archive(
      _ArchiveCore()..history.add(entry),
      _MemoryImageStore()..images[entry.id] = _testPng,
    );
    final runtime = _runtime();
    await tester.pumpWidget(_host(runtime: runtime, archive: archive));
    await _pumpFrames(tester);

    expect(
      find.byKey(const ValueKey('screenshot-workbench-history-alignment-note')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('screenshot-history-translation-overlay-0')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('screenshot-workbench-history-overlay-toggle')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    await _dispose(tester, runtime, archive);
  });

  testWidgets('zoomed screenshot history keeps the translated OCR overlay', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(3000, 1800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final entry = _entry(
      'shot-aligned-zoom',
      source: 'Hello world',
      translated: '你好，世界',
      screenshotOcrLayout: {
        'version': 1,
        'coordinateSpace': 'image_pixels',
        'imageWidth': 1,
        'imageHeight': 1,
        'sourceText': 'Hello world',
        'blocks': [
          {'text': 'Hello world', 'left': 0, 'top': 0, 'width': 1, 'height': 1},
        ],
      },
      translatedSourceBlockIndices: const [0],
    );
    final archive = _archive(
      _ArchiveCore()..history.add(entry),
      _MemoryImageStore()..images[entry.id] = _testPng,
    );
    final runtime = _runtime();
    await tester.pumpWidget(_host(runtime: runtime, archive: archive));
    await _pumpFrames(tester);

    await tester.tap(
      find.byKey(const ValueKey('screenshot-workbench-image-preview-open')),
    );
    await _pumpFrames(tester);

    expect(
      find.byKey(
        const ValueKey('screenshot-history-image-dialog-translation-overlay-0'),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('screenshot-workbench-image-dialog')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    await tester.tap(find.byTooltip('关闭原图预览'));
    await _pumpFrames(tester);
    await _dispose(tester, runtime, archive);
  });

  testWidgets('extreme screenshot aspect ratio keeps history overlay safe', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(3000, 1800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final imageBytes = (await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder, const Rect.fromLTWH(0, 0, 4000, 1));
      canvas.drawColor(Colors.white, ui.BlendMode.src);
      final picture = recorder.endRecording();
      final image = await picture.toImage(4000, 1);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      picture.dispose();
      return data!.buffer.asUint8List();
    }))!;
    final entry = _entry(
      'shot-extreme-ratio',
      source: 'Hello world',
      translated: '你好，世界',
      screenshotOcrLayout: {
        'version': 1,
        'coordinateSpace': 'image_pixels',
        'imageWidth': 4000,
        'imageHeight': 1,
        'sourceText': 'Hello world',
        'blocks': [
          {
            'text': 'Hello world',
            'left': 0,
            'top': 0,
            'width': 4000,
            'height': 1,
          },
        ],
      },
      translatedSourceBlockIndices: const [0],
    );
    final archive = _archive(
      _ArchiveCore()..history.add(entry),
      _MemoryImageStore()..images[entry.id] = imageBytes,
    );
    final runtime = _runtime();
    await tester.pumpWidget(_host(runtime: runtime, archive: archive));
    await _pumpFrames(tester);

    await tester.tap(
      find.byKey(const ValueKey('screenshot-workbench-image-preview-open')),
    );
    await _pumpFrames(tester);

    expect(
      find.byKey(
        const ValueKey('screenshot-history-image-dialog-translation-overlay-0'),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    await tester.tap(find.byTooltip('关闭原图预览'));
    await _pumpFrames(tester);
    await _dispose(tester, runtime, archive);
  });

  testWidgets('unmatched OCR paragraphs keep the full text comparison', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(3000, 1800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final entry = _entry(
      'shot-unmatched-paragraphs',
      source: 'Source one.\n\nSource two.',
      translated: '只有一段完整译文。',
    );
    final core = _ArchiveCore()..history.add(entry);
    final archive = _archive(core, _MemoryImageStore());
    final runtime = _runtime();
    await tester.pumpWidget(_host(runtime: runtime, archive: archive));
    await _pumpFrames(tester);

    expect(
      find.byKey(const ValueKey('screenshot-workbench-ocr-text')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('screenshot-workbench-translation-text')),
      findsOneWidget,
    );
    expect(find.text('段落对照 · 按文本换行分组，不代表原图坐标对齐'), findsNothing);
    expect(find.text('Source one.\n\nSource two.'), findsOneWidget);
    expect(
      tester
          .widget<SelectableText>(
            find.byKey(const ValueKey('screenshot-workbench-translation-text')),
          )
          .data,
      '只有一段完整译文。',
    );

    await _dispose(tester, runtime, archive);
  });

  testWidgets(
    'Chinese OCR selection opens a closable local dictionary detail',
    (tester) async {
      final entry = _entry('shot-chinese-word', source: '我喜欢苹果');
      final core = _ArchiveCore()..history.add(entry);
      final archive = _archive(core, _MemoryImageStore());
      final runtime = _runtime();
      final lookedUp = <String>[];
      await tester.pumpWidget(
        _host(
          runtime: runtime,
          archive: archive,
          lookupDictionary: (word) async {
            lookedUp.add(word);
            return const DictionaryEntry(
              word: 'apple',
              ipa: '/ˈæpəl/',
              partOfSpeech: 'n.',
              meanings: ['苹果'],
              example: 'An apple is red.',
              exampleTranslation: '苹果是红色的。',
            );
          },
        ),
      );
      await _pumpFrames(tester);

      final sourceText = tester.widget<SelectableText>(
        find.byKey(const ValueKey('screenshot-workbench-ocr-text')),
      );
      sourceText.onSelectionChanged!(
        const TextSelection(baseOffset: 3, extentOffset: 5),
        SelectionChangedCause.longPress,
      );
      await tester.pump();
      expect(find.text('已选中 “苹果” · 可查本地释义'), findsOneWidget);
      final lookupButton = find.byKey(
        const ValueKey('screenshot-workbench-lookup-word'),
      );
      await tester.ensureVisible(lookupButton);
      await tester.tap(lookupButton);
      await _pumpFrames(tester);

      expect(lookedUp, ['苹果']);
      expect(find.text('apple'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('• 苹果'),
        ),
        findsOneWidget,
      );
      expect(find.text('An apple is red.'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('我喜欢苹果'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('关闭'));
      await _pumpFrames(tester);
      expect(find.text('An apple is red.'), findsNothing);
      expect(tester.takeException(), isNull);

      await _dispose(tester, runtime, archive);
    },
  );

  testWidgets(
    'English word lookup can be revisited from workspace lookup history',
    (tester) async {
      final entry = _entry('shot-english-word', source: 'Hello world');
      final core = _ArchiveCore()..history.add(entry);
      final archive = _archive(core, _MemoryImageStore());
      final runtime = _runtime();
      final lookedUp = <String>[];
      await tester.pumpWidget(
        _host(
          runtime: runtime,
          archive: archive,
          lookupDictionary: (word) async {
            lookedUp.add(word);
            return const DictionaryEntry(
              word: 'world',
              ipa: '/wɜːld/',
              partOfSpeech: 'n.',
              meanings: ['世界'],
              example: 'The world is changing.',
              exampleTranslation: '世界在变化。',
            );
          },
        ),
      );
      await _pumpFrames(tester);

      final sourceText = tester.widget<SelectableText>(
        find.byKey(const ValueKey('screenshot-workbench-ocr-text')),
      );
      sourceText.onSelectionChanged!(
        const TextSelection(baseOffset: 6, extentOffset: 11),
        SelectionChangedCause.longPress,
      );
      await tester.pump();
      final lookupButton = find.byKey(
        const ValueKey('screenshot-workbench-lookup-word'),
      );
      await tester.ensureVisible(lookupButton);
      await tester.tap(lookupButton);
      await _pumpFrames(tester);
      expect(find.text('The world is changing.'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Hello world'),
        ),
        findsOneWidget,
      );

      await tester.tap(find.text('关闭'));
      await _pumpFrames(tester);
      expect(
        find.byKey(const ValueKey('screenshot-workbench-lookup-history')),
        findsOneWidget,
      );
      final historyButton = find.byKey(
        const ValueKey('screenshot-workbench-lookup-history'),
      );
      await tester.ensureVisible(historyButton);
      await tester.tap(historyButton);
      await _pumpFrames(tester);
      expect(find.text('最近查词'), findsOneWidget);
      await tester.tap(find.byType(ListTile).last);
      await _pumpFrames(tester);
      expect(lookedUp, ['world']);
      expect(find.text('The world is changing.'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await _dispose(tester, runtime, archive);
    },
  );

  testWidgets(
    'workbench dictionary lookup history survives closing and reopening the workspace',
    (tester) async {
      final historyEntry = _entry(
        'shot-workbench-history',
        source: 'Hello world',
        translated: '你好，世界',
      );
      final core = _ArchiveCore()..history.add(historyEntry);
      final lookupHistoryRecords = <ScreenshotDictionaryLookupHistoryRecord>[];
      final lookupHistoryStore = _MemoryDictionaryLookupHistoryStore(
        lookupHistoryRecords,
      );
      final lookedUp = <String>[];

      ScreenshotTranslationArchiveController newArchive() =>
          _archive(core, _MemoryImageStore());

      final runtime = _runtime();
      final archive = newArchive();
      await tester.pumpWidget(
        _host(
          runtime: runtime,
          archive: archive,
          dictionaryLookupHistoryStore: lookupHistoryStore,
          lookupDictionary: (word) async {
            lookedUp.add(word);
            return const DictionaryEntry(
              word: 'world',
              ipa: '/wɜːld/',
              partOfSpeech: 'n.',
              meanings: ['世界'],
              example: 'The world is changing.',
              exampleTranslation: '世界在变化。',
            );
          },
        ),
      );
      await _pumpFrames(tester);

      tester
          .widget<SelectableText>(
            find.byKey(const ValueKey('screenshot-workbench-ocr-text')),
          )
          .onSelectionChanged!(
        const TextSelection(baseOffset: 6, extentOffset: 11),
        SelectionChangedCause.longPress,
      );
      await tester.pump();
      final lookupButton = find.byKey(
        const ValueKey('screenshot-workbench-lookup-word'),
      );
      await tester.ensureVisible(lookupButton);
      await tester.tap(lookupButton);
      await _pumpFrames(tester);
      expect(find.text('The world is changing.'), findsOneWidget);
      await tester.tap(find.text('关闭'));
      await _pumpFrames(tester);
      expect(lookedUp, ['world']);
      expect(lookupHistoryRecords, hasLength(1));

      await tester.pumpWidget(const SizedBox.shrink());
      await runtime.shutdown();
      runtime.dispose();
      archive.dispose();

      final reopenedRuntime = _runtime();
      final reopenedArchive = newArchive();
      await tester.pumpWidget(
        _host(
          runtime: reopenedRuntime,
          archive: reopenedArchive,
          dictionaryLookupHistoryStore: lookupHistoryStore,
        ),
      );
      await _pumpFrames(tester);

      expect(find.text('最近查词 · 1'), findsOneWidget);
      final lookupHistoryButton = find.byKey(
        const ValueKey('screenshot-workbench-lookup-history'),
      );
      await tester.ensureVisible(lookupHistoryButton);
      await _pumpFrames(tester);
      await tester.tap(lookupHistoryButton);
      await _pumpFrames(tester);
      expect(find.text('最近查词'), findsOneWidget);
      expect(find.textContaining('本机保留最近 24 条查词记录'), findsOneWidget);
      await tester.tap(find.byType(ListTile).first);
      await _pumpFrames(tester);
      expect(find.text('The world is changing.'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Hello world'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('你好，世界'),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);

      await _dispose(tester, reopenedRuntime, reopenedArchive);
    },
  );

  testWidgets(
    'workbench distinguishes saved model word trials from dictionary entries',
    (tester) async {
      final modelTrial = ScreenshotDictionaryLookupHistoryRecord.modelTrial(
        lookupQuery: 'language',
        sessionId: 'shot-model-trial',
        sourceContext: 'The study of language helps people.',
        recognizedTextSnapshot: 'Full OCR: The study of language helps people.',
        translationSnapshot: '语言研究有助于人们。',
        modelTranslation: '语言；语言学体系',
        recordedAt: DateTime.utc(2026, 11, 5),
      );
      final store = _MemoryDictionaryLookupHistoryStore([modelTrial]);
      final core = _ArchiveCore()
        ..history.add(
          _entry(
            'shot-model-trial-workbench',
            source: 'The study of language helps people.',
            translated: '语言研究有助于人们。',
          ),
        );
      final runtime = _runtime();
      final archive = _archive(core, _MemoryImageStore());
      await tester.pumpWidget(
        _host(
          runtime: runtime,
          archive: archive,
          dictionaryLookupHistoryStore: store,
        ),
      );
      await _pumpFrames(tester);

      final historyButton = find.byKey(
        const ValueKey('screenshot-workbench-lookup-history'),
      );
      await tester.ensureVisible(historyButton);
      await tester.tap(historyButton);
      await _pumpFrames(tester);
      expect(find.text('language · 模型试译'), findsOneWidget);
      expect(find.textContaining('模型试译：语言；语言学体系'), findsOneWidget);
      await tester.tap(find.byType(ListTile).first);
      await _pumpFrames(tester);

      expect(find.text('模型试译记录 · language'), findsOneWidget);
      expect(find.text('模型试译结果 · 非词典释义'), findsOneWidget);
      expect(find.text('语言；语言学体系'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('The study of language helps people.'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Full OCR: The study of language helps people.'),
        ),
        findsOneWidget,
      );
      expect(find.text('本地词典没有可展示的释义或例句。'), findsNothing);
      expect(tester.takeException(), isNull);

      await _dispose(tester, runtime, archive);
    },
  );

  testWidgets(
    'OCR selection adds the exact word with history context snapshot',
    (tester) async {
      final entry = _entry(
        'shot-word',
        source: "The user's quick test.",
        translated: 'A quick answer',
      );
      final core = _ArchiveCore()..history.add(entry);
      final archive = _archive(core, _MemoryImageStore());
      final runtime = _runtime();
      final calls = <Map<String, String>>[];
      await tester.pumpWidget(
        _host(
          runtime: runtime,
          archive: archive,
          onAddScreenshotWord:
              ({
                required word,
                required sourceContext,
                required sourceTranslation,
                required sourceHistoryId,
              }) async {
                calls.add({
                  'word': word,
                  'context': sourceContext,
                  'translation': sourceTranslation,
                  'id': sourceHistoryId,
                });
                return true;
              },
        ),
      );
      await _pumpFrames(tester);

      final ocrFinder = find.byKey(
        const ValueKey('screenshot-workbench-ocr-text'),
      );
      final ocr = tester.widget<SelectableText>(ocrFinder);
      final textPainter = TextPainter(
        text: TextSpan(
          text: ocr.data,
          style: DefaultTextStyle.of(tester.element(ocrFinder)).style
              .merge(ocr.style),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: tester.getSize(ocrFinder).width);
      final origin = tester.getTopLeft(ocrFinder);
      final start = textPainter.getOffsetForCaret(
        const TextPosition(offset: 11),
        Rect.zero,
      );
      final end = textPainter.getOffsetForCaret(
        const TextPosition(offset: 16),
        Rect.zero,
      );
      final selectionY = origin.dy + 12;
      final drag = await tester.startGesture(
        Offset(origin.dx + start.dx + 2, selectionY),
        kind: PointerDeviceKind.mouse,
        buttons: kPrimaryMouseButton,
      );
      await drag.moveTo(Offset(origin.dx + end.dx - 2, selectionY));
      await drag.up();
      await _pumpFrames(tester);
      expect(find.text('已选中 “quick”'), findsOneWidget);

      final addWord = find.byKey(
        const ValueKey('screenshot-workbench-add-word'),
      );
      await tester.ensureVisible(addWord);
      await tester.pump();
      await tester.tap(addWord);
      await _pumpFrames(tester);
      expect(calls, [
        {
          'word': 'quick',
          'context': "The user's quick test.",
          'translation': 'A quick answer',
          'id': 'shot-word',
        },
      ]);
      expect(find.text('已加入截屏生词；词义可在复习时填写。'), findsOneWidget);

      final translationFinder = find.byKey(
        const ValueKey('screenshot-workbench-translation-text'),
      );
      final translation = tester.widget<SelectableText>(translationFinder);
      translation.onSelectionChanged!(
        const TextSelection(baseOffset: 8, extentOffset: 14),
        SelectionChangedCause.drag,
      );
      await tester.pump();
      expect(find.text('已选中 “quick”'), findsNothing);
      expect(find.text('在 OCR 原文中选择英文词可加入生词；中英文词语均可查释义'), findsOneWidget);
      expect(calls, hasLength(1));
      expect(tester.widget<FilledButton>(addWord).onPressed, isNull);

      await _dispose(tester, runtime, archive);
    },
  );

  testWidgets(
    'search filters source or translated text through the archive API',
    (tester) async {
      final core = _ArchiveCore()
        ..history.addAll([
          _entry('shot-apple', source: 'An apple is red', translated: '苹果是红的'),
          _entry(
            'shot-orbit',
            source: 'A planet in orbit',
            translated: '行星在轨道上',
          ),
        ]);
      final archive = _archive(core, _MemoryImageStore());
      final runtime = _runtime();
      await tester.pumpWidget(_host(runtime: runtime, archive: archive));
      await _pumpFrames(tester);

      await tester.enterText(
        find.byKey(const ValueKey('screenshot-workbench-search')),
        '轨道',
      );
      await tester.pump(const Duration(milliseconds: 320));
      await _pumpFrames(tester);

      expect(
        find.byKey(const ValueKey('screenshot-history-row-shot-orbit')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('screenshot-history-row-shot-apple')),
        findsNothing,
      );
      expect(core.pageCalls.last.query, '轨道');

      await _dispose(tester, runtime, archive);
    },
  );

  testWidgets('deleting one history row removes its image and text entry', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1500, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final entry = _entry('shot-delete');
    final core = _ArchiveCore()..history.add(entry);
    final store = _MemoryImageStore()..images[entry.id] = _testPng;
    final archive = _archive(core, store);
    final runtime = _runtime();
    await tester.pumpWidget(_host(runtime: runtime, archive: archive));
    await _pumpFrames(tester);

    await tester.tap(
      find.byKey(const ValueKey('screenshot-workbench-delete-entry')),
    );
    await _pumpFrames(tester);
    expect(find.text('删除这条截屏历史？'), findsOneWidget);
    await tester.tap(find.text('删除历史并清理无引用原图'));
    await _pumpFrames(tester);

    expect(core.history, isEmpty);
    expect(core.deletedIds, ['shot-delete']);
    expect(store.images, isEmpty);
    expect(find.text('还没有截屏翻译'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await _dispose(tester, runtime, archive);
  });

  testWidgets('compact width switches between history and readable detail', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(680, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final entry = _entry(
      'shot-compact',
      source: 'A narrow layout keeps text visible.',
    );
    final core = _ArchiveCore()..history.add(entry);
    final archive = _archive(core, _MemoryImageStore());
    final runtime = _runtime();
    await tester.pumpWidget(_host(runtime: runtime, archive: archive));
    await _pumpFrames(tester);

    expect(
      find.byKey(const ValueKey('screenshot-history-row-shot-compact')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('screenshot-history-row-shot-compact')),
    );
    await _pumpFrames(tester);
    expect(
      find.byKey(const ValueKey('screenshot-workbench-back-to-history')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('screenshot-workbench-ocr-text')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.tap(
      find.byKey(const ValueKey('screenshot-workbench-back-to-history')),
    );
    await _pumpFrames(tester);
    expect(
      find.byKey(const ValueKey('screenshot-history-row-shot-compact')),
      findsOneWidget,
    );

    await _dispose(tester, runtime, archive);
  });

  testWidgets(
    'clear images confirmation reports storage and preserves text history',
    (tester) async {
      tester.view.physicalSize = const Size(1500, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final entry = _entry('shot-clear');
      final core = _ArchiveCore()..history.add(entry);
      final store = _MemoryImageStore()..images[entry.id] = _testPng;
      final archive = _archive(core, store);
      final runtime = _runtime();
      final desktop = _desktopController();
      await desktop.initialize();
      await tester.pumpWidget(
        _host(runtime: runtime, archive: archive, desktop: desktop),
      );
      await _pumpFrames(tester);

      await tester.tap(
        find.byKey(const ValueKey('screenshot-workbench-toggle-settings')),
      );
      await _pumpFrames(tester);
      expect(find.textContaining('本机原图 1 张'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('screenshot-workbench-clear-images')),
      );
      await _pumpFrames(tester);
      expect(find.textContaining('将删除 1 张截图原图'), findsOneWidget);
      await tester.tap(find.text('清理图片'));
      await _pumpFrames(tester);

      expect(store.images, isEmpty);
      expect(core.history, hasLength(1));
      expect(archive.entries, hasLength(1));
      expect(find.text('已清理 1 张原图；OCR 原文和译文历史仍保留。'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await runtime.shutdown();
      runtime.dispose();
      archive.dispose();
      await desktop.quit();
      desktop.dispose();
    },
  );

  testWidgets(
    'page settings switch stores the real orb and image preferences',
    (tester) async {
      tester.view.physicalSize = const Size(1500, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final archive = _archive(_ArchiveCore(), _MemoryImageStore());
      final runtime = _runtime();
      final desktop = _desktopController();
      await desktop.initialize();
      await tester.pumpWidget(
        _host(runtime: runtime, archive: archive, desktop: desktop),
      );
      await _pumpFrames(tester);
      await tester.tap(
        find.byKey(const ValueKey('screenshot-workbench-toggle-settings')),
      );
      await _pumpFrames(tester);

      await tester.tap(
        find.byKey(const ValueKey('screenshot-workbench-orb-toggle')),
      );
      await _pumpFrames(tester);
      expect(desktop.preferences.orbEnabled, isFalse);
      expect(desktop.orbError, isNull);
      await tester.tap(
        find.byKey(const ValueKey('screenshot-workbench-save-images-toggle')),
      );
      await _pumpFrames(tester);
      expect(desktop.preferences.saveScreenshotImages, isFalse);
      expect(find.text('状态：悬浮球已关闭'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await runtime.shutdown();
      runtime.dispose();
      archive.dispose();
      await desktop.quit();
      desktop.dispose();
    },
  );

  testWidgets('orb is not reported as visible until its open ACK arrives', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1500, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final pendingOpen = Completer<void>();
    final archive = _archive(_ArchiveCore(), _MemoryImageStore());
    final runtime = _runtime();
    final desktop = _desktopController(onOrbOpen: () => pendingOpen.future);
    final initialized = desktop.initialize();
    await tester.pump();
    await tester.pumpWidget(
      _host(
        runtime: runtime,
        archive: archive,
        desktop: desktop,
        settingsRequestVersion: 1,
      ),
    );
    await _pumpFrames(tester);

    expect(find.text('状态：正在启动悬浮球…'), findsOneWidget);
    expect(find.text('状态：悬浮球已显示'), findsNothing);
    expect(find.text('悬浮球：启动中'), findsOneWidget);
    expect(find.text('悬浮球：已显示'), findsNothing);

    pendingOpen.complete();
    await initialized;
    await _pumpFrames(tester);
    expect(find.text('状态：悬浮球已显示'), findsOneWidget);
    expect(find.text('悬浮球：已显示'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await runtime.shutdown();
    runtime.dispose();
    archive.dispose();
    await desktop.quit();
    desktop.dispose();
  });

  testWidgets('orb close failure offers the matching close retry action', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(680, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var closeAttempts = 0;
    final archive = _archive(_ArchiveCore(), _MemoryImageStore());
    final runtime = _runtime();
    final desktop = _desktopController(
      onOrbClose: () async {
        if (++closeAttempts == 1) throw StateError('orb close failed');
      },
    );
    await desktop.initialize();
    await tester.pumpWidget(
      _host(
        runtime: runtime,
        archive: archive,
        desktop: desktop,
        settingsRequestVersion: 1,
      ),
    );
    await _pumpFrames(tester);

    expect(
      await desktop.update(desktop.preferences.copyWith(orbEnabled: false)),
      isTrue,
    );
    await _pumpFrames(tester);

    expect(find.text('悬浮球关闭失败，请重试。'), findsOneWidget);
    expect(find.text('重试关闭'), findsOneWidget);
    expect(find.text('重试显示'), findsNothing);
    await tester.tap(
      find.byKey(const ValueKey('screenshot-workbench-retry-orb')),
    );
    await _pumpFrames(tester);
    expect(desktop.orbRuntimeState, ScreenshotOrbRuntimeState.disabled);
    expect(closeAttempts, 2);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await runtime.shutdown();
    runtime.dispose();
    archive.dispose();
    await desktop.quit();
    desktop.dispose();
  });

  testWidgets('initial settings request opens the local settings panel', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(680, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final archive = _archive(_ArchiveCore(), _MemoryImageStore());
    final runtime = _runtime();
    final desktop = _desktopController();
    await desktop.initialize();
    await tester.pumpWidget(
      _host(
        runtime: runtime,
        archive: archive,
        desktop: desktop,
        settingsRequestVersion: 1,
      ),
    );
    await _pumpFrames(tester);

    expect(
      find.byKey(const ValueKey('screenshot-workbench-save-images-toggle')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('screenshot-workbench-settings-back')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await runtime.shutdown();
    runtime.dispose();
    archive.dispose();
    await desktop.quit();
    desktop.dispose();
  });

  testWidgets('recorder shows the pending shortcut pause state', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1500, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final hotKeys = _HotKeys();
    final unregisterStarted = Completer<void>();
    final unregisterGate = Completer<void>();
    hotKeys.unregisterStarted = unregisterStarted;
    hotKeys.unregisterGate = unregisterGate;
    final archive = _archive(_ArchiveCore(), _MemoryImageStore());
    final runtime = _runtime();
    final desktop = _desktopController(hotKeys: hotKeys);
    await desktop.initialize();
    await tester.pumpWidget(
      _host(
        runtime: runtime,
        archive: archive,
        desktop: desktop,
        settingsRequestVersion: 1,
      ),
    );
    await _pumpFrames(tester);

    await tester.tap(
      find.byKey(const ValueKey('screenshot-workbench-record-hotkey')),
    );
    await unregisterStarted.future;
    await tester.pump();

    expect(find.text('正在准备录制…'), findsOneWidget);
    expect(find.text('正在暂停快捷键…'), findsOneWidget);
    expect(find.text('录制期间暂停当前快捷键。'), findsOneWidget);

    unregisterGate.complete();
    await _pumpFrames(tester);
    expect(find.text('取消录制'), findsOneWidget);
    expect(find.text('请按组合键 · Esc 取消'), findsOneWidget);

    await desktop.endHotKeyRecording();
    await tester.pumpWidget(const SizedBox.shrink());
    await runtime.shutdown();
    runtime.dispose();
    archive.dispose();
    await desktop.quit();
    desktop.dispose();
  });

  testWidgets('closing while recorder start is queued restores the shortcut', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1500, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = _PreferenceStore();
    final writeStarted = Completer<void>();
    final writeGate = Completer<void>();
    store.writeStarted = writeStarted;
    store.writeGate = writeGate;
    final hotKeys = _HotKeys();
    final restoredRegistration = Completer<void>();
    hotKeys.secondRegistrationCompleted = restoredRegistration;
    final archive = _archive(_ArchiveCore(), _MemoryImageStore());
    final runtime = _runtime();
    final desktop = _desktopController(store: store, hotKeys: hotKeys);
    await desktop.initialize();
    final pendingSave = desktop.update(
      desktop.preferences.copyWith(saveScreenshotImages: false),
    );
    await writeStarted.future;
    await tester.pumpWidget(
      _host(
        runtime: runtime,
        archive: archive,
        desktop: desktop,
        settingsRequestVersion: 1,
      ),
    );
    await _pumpFrames(tester);

    await tester.tap(
      find.byKey(const ValueKey('screenshot-workbench-record-hotkey')),
    );
    await tester.pump();
    expect(desktop.hotKeyRecording, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());

    writeGate.complete();
    await pendingSave;
    for (
      var frame = 0;
      frame < 10 && !restoredRegistration.isCompleted;
      frame++
    ) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(restoredRegistration.isCompleted, isTrue);
    expect(desktop.hotKeyRecording, isFalse);
    expect(desktop.hotKeyRegistered, isTrue);
    expect(hotKeys.registered, hasLength(2));

    await runtime.shutdown();
    runtime.dispose();
    archive.dispose();
    await desktop.quit();
    desktop.dispose();
  });

  testWidgets('recorder stays disabled while the selected key is being saved', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1500, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final hotKeys = _HotKeys();
    final archive = _archive(_ArchiveCore(), _MemoryImageStore());
    final runtime = _runtime();
    final desktop = _desktopController(hotKeys: hotKeys);
    await desktop.initialize();
    await tester.pumpWidget(
      _host(
        runtime: runtime,
        archive: archive,
        desktop: desktop,
        settingsRequestVersion: 1,
      ),
    );
    await _pumpFrames(tester);
    await tester.tap(
      find.byKey(const ValueKey('screenshot-workbench-record-hotkey')),
    );
    await _pumpFrames(tester);

    final registrationStarted = Completer<void>();
    final registrationGate = Completer<void>();
    hotKeys.registerStarted = registrationStarted;
    hotKeys.registerGate = registrationGate;
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyDownEvent(
      LogicalKeyboardKey.keyU,
      physicalKey: PhysicalKeyboardKey.keyU,
    );
    await tester.sendKeyUpEvent(
      LogicalKeyboardKey.keyU,
      physicalKey: PhysicalKeyboardKey.keyU,
    );
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await registrationStarted.future;
    await tester.pump();

    final recordButton = tester.widget<OutlinedButton>(
      find.byKey(const ValueKey('screenshot-workbench-record-hotkey')),
    );
    expect(find.text('正在保存快捷键…'), findsOneWidget);
    expect(recordButton.onPressed, isNull);

    registrationGate.complete();
    await _pumpFrames(tester);
    expect(
      desktop.preferences.hotKey,
      const ScreenshotHotKey(keyCode: 0x70018, modifiers: ['control', 'alt']),
    );
    expect(find.text('录制新快捷键'), findsOneWidget);
    expect(
      tester
          .widget<OutlinedButton>(
            find.byKey(const ValueKey('screenshot-workbench-record-hotkey')),
          )
          .onPressed,
      isNotNull,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await runtime.shutdown();
    runtime.dispose();
    archive.dispose();
    await desktop.quit();
    desktop.dispose();
  });

  testWidgets('selected shortcut persists if settings closes during saving', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1500, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = _PreferenceStore();
    final writeStarted = Completer<void>();
    store.writeStarted = writeStarted;
    final hotKeys = _HotKeys();
    final registrationStarted = Completer<void>();
    final registrationGate = Completer<void>();
    final archive = _archive(_ArchiveCore(), _MemoryImageStore());
    final runtime = _runtime();
    final desktop = _desktopController(store: store, hotKeys: hotKeys);
    await desktop.initialize();
    await tester.pumpWidget(
      _host(
        runtime: runtime,
        archive: archive,
        desktop: desktop,
        settingsRequestVersion: 1,
      ),
    );
    await _pumpFrames(tester);
    await tester.tap(
      find.byKey(const ValueKey('screenshot-workbench-record-hotkey')),
    );
    await _pumpFrames(tester);
    hotKeys.registerStarted = registrationStarted;
    hotKeys.registerGate = registrationGate;
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyDownEvent(
      LogicalKeyboardKey.keyU,
      physicalKey: PhysicalKeyboardKey.keyU,
    );
    await tester.sendKeyUpEvent(
      LogicalKeyboardKey.keyU,
      physicalKey: PhysicalKeyboardKey.keyU,
    );
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await registrationStarted.future;

    await tester.pumpWidget(const SizedBox.shrink());
    registrationGate.complete();
    for (var frame = 0; frame < 10 && !writeStarted.isCompleted; frame++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(writeStarted.isCompleted, isTrue);
    for (var frame = 0; frame < 10; frame++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    const selected = ScreenshotHotKey(
      keyCode: 0x70018,
      modifiers: ['control', 'alt'],
    );
    expect(desktop.preferences.hotKey, selected);
    expect(store.value.hotKey, selected);

    await runtime.shutdown();
    runtime.dispose();
    archive.dispose();
    await desktop.quit();
    desktop.dispose();
  });

  testWidgets('production workbench recorder rejects occupied chords', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1500, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = _PreferenceStore();
    final hotKeys = _HotKeys();
    final archive = _archive(_ArchiveCore(), _MemoryImageStore());
    final runtime = _runtime();
    final desktop = _desktopController(store: store, hotKeys: hotKeys);
    await desktop.initialize();
    await tester.pumpWidget(
      _host(runtime: runtime, archive: archive, desktop: desktop),
    );
    await _pumpFrames(tester);
    await tester.tap(
      find.byKey(const ValueKey('screenshot-workbench-toggle-settings')),
    );
    await _pumpFrames(tester);

    const occupied = ScreenshotHotKey(
      keyCode: 0x70018,
      modifiers: ['control', 'alt'],
    );
    final original = const ScreenshotTranslationPreferences().hotKey;
    hotKeys.conflictKey = occupied;
    await tester.tap(
      find.byKey(const ValueKey('screenshot-workbench-record-hotkey')),
    );
    await _pumpFrames(tester);
    expect(find.text('请按组合键 · Esc 取消'), findsOneWidget);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyDownEvent(
      LogicalKeyboardKey.keyU,
      physicalKey: PhysicalKeyboardKey.keyU,
    );
    await tester.sendKeyUpEvent(
      LogicalKeyboardKey.keyU,
      physicalKey: PhysicalKeyboardKey.keyU,
    );
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await _pumpFrames(tester);

    expect(desktop.preferences.hotKey, original);
    expect(store.value.hotKey, original);
    expect(desktop.hotKeyRegistered, isTrue);
    expect(hotKeys.registered, contains(occupied));
    expect(find.text(original.label), findsOneWidget);
    expect(find.textContaining('占用'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await runtime.shutdown();
    runtime.dispose();
    archive.dispose();
    await desktop.quit();
    desktop.dispose();
  });

  testWidgets('result window failure is visible and can be retried', (
    tester,
  ) async {
    var failWindow = true;
    var windowCreations = 0;
    final runtime = ScreenshotTranslationRuntime(
      capture: () async => CapturedData(
        width: 20,
        height: 10,
        bytes: Uint8List.fromList([1]),
        left: -40,
      ),
      recognize: (_, [_]) async => 'recognized text',
      translate: (
        source,
        direction, {
        required origin,
        required historyEntryId,
        required screenshotCaptureId,
      }) async => '译文',
      saveScreenshotImages: () => false,
      createResultWindow: () async {
        windowCreations++;
        if (failWindow) throw StateError('simulated child window failure');
        return _TestResultWindow();
      },
    );
    await runtime.startCapture();
    expect(runtime.windowError, isNotNull);
    failWindow = false;
    final archive = _archive(_ArchiveCore(), _MemoryImageStore());
    await tester.pumpWidget(_host(runtime: runtime, archive: archive));
    await _pumpFrames(tester);

    expect(find.text('结果窗口连接失败，请重新截取或从主界面恢复。'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('screenshot-workbench-reopen-result')),
      findsOneWidget,
    );
    final failedAttempts = windowCreations;
    await tester.tap(
      find.byKey(const ValueKey('screenshot-workbench-reopen-result')),
    );
    await _pumpFrames(tester);

    expect(windowCreations, failedAttempts + 1);
    expect(runtime.windowError, isNull);
    expect(find.text('最近一次截屏翻译已完成，可在下方历史中查看。'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await runtime.shutdown();
    runtime.dispose();
    archive.dispose();
  });
}

Widget _host({
  required ScreenshotTranslationRuntime runtime,
  required ScreenshotTranslationArchiveController archive,
  ScreenshotTranslationDesktopController? desktop,
  int settingsRequestVersion = 0,
  ScreenshotWordAddCallback? onAddScreenshotWord,
  ScreenshotDictionaryLookup? lookupDictionary,
  ScreenshotDictionaryLookupHistoryStore? dictionaryLookupHistoryStore,
}) => MaterialApp(
  home: Scaffold(
    body: ScreenshotTranslationWorkspace(
      runtime: runtime,
      archiveController: archive,
      desktopController: desktop,
      settingsRequestVersion: settingsRequestVersion,
      onOpenModels: () {},
      onAddScreenshotWord: onAddScreenshotWord,
      lookupDictionary: lookupDictionary,
      dictionaryLookupHistoryStore: dictionaryLookupHistoryStore,
    ),
  ),
);

ScreenshotTranslationRuntime _runtime() => ScreenshotTranslationRuntime(
  capture: () async => null,
  recognize: (_, [_]) async => '',
  translate: (
    source,
    direction, {
    required origin,
    required historyEntryId,
    required screenshotCaptureId,
  }) async => '译文',
);

ScreenshotTranslationArchiveController _archive(
  _ArchiveCore core,
  ScreenshotTranslationImageStore imageStore,
) => ScreenshotTranslationArchiveController(
  coreFactory: () => core,
  imageStore: imageStore,
  pageSize: 50,
);

TranslationHistoryEntryData _entry(
  String id, {
  String source = 'Hello world',
  String translated = '你好，世界',
  Map<String, Object?>? screenshotOcrLayout,
  List<int>? translatedSourceBlockIndices,
}) => TranslationHistoryEntryData(
  id: id,
  sourceText: source,
  translatedText: translated,
  providerId: 'local-test',
  sourceLanguage: 'english',
  targetLanguage: 'chinese',
  createdAt: '2026-10-07T08:30:00.000Z',
  origin: 'screenshot_translation',
  screenshotOcrLayout: screenshotOcrLayout,
  translatedSourceBlockIndices: translatedSourceBlockIndices,
);

Future<void> _dispose(
  WidgetTester tester,
  ScreenshotTranslationRuntime runtime,
  ScreenshotTranslationArchiveController archive,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await runtime.shutdown();
  runtime.dispose();
  archive.dispose();
}

Future<void> _pumpFrames(WidgetTester tester) async {
  for (var frame = 0; frame < 8; frame++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

final Uint8List _testPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScL/nwAAAABJRU5ErkJggg==',
);

class _TestResultWindow implements ScreenshotTranslationResultHandle {
  @override
  Future<void> update(ScreenshotTranslationSession? session) async {}

  @override
  Future<void> hide() async {}
}

class _ArchiveCore
    implements
        AppCore,
        PagedTranslationHistoryCore,
        DeletableTranslationHistoryCore {
  final List<TranslationHistoryEntryData> history = [];
  final List<String> deletedIds = [];
  final List<({int limit, int offset, String? origin, String query})>
  pageCalls = [];

  @override
  List<TranslationHistoryEntryData> listTranslationHistoryPage({
    int limit = 50,
    int offset = 0,
    String? origin,
    String query = '',
  }) {
    pageCalls.add((limit: limit, offset: offset, origin: origin, query: query));
    final normalized = query.toLowerCase();
    return history
        .where((entry) => origin == null || entry.origin == origin)
        .where(
          (entry) =>
              normalized.isEmpty ||
              entry.sourceText.toLowerCase().contains(normalized) ||
              entry.translatedText.toLowerCase().contains(normalized),
        )
        .skip(offset)
        .take(limit)
        .toList();
  }

  @override
  void deleteTranslationHistory(List<String> ids) {
    deletedIds.addAll(ids);
    history.removeWhere((entry) => ids.contains(entry.id));
  }

  @override
  List<TranslationHistoryEntryData> listTranslationHistory({int limit = 500}) =>
      history.take(limit).toList();

  @override
  CoreHealth health() =>
      const CoreHealth(schemaVersion: 1, coreVersion: 'test');

  @override
  void saveProviderProfile(ProviderProfileData profile) {}

  @override
  void deleteProviderProfile(String providerId) {}

  @override
  List<ProviderProfileData> listProviderProfiles() => const [];

  @override
  void recordActivity(ActivityEventData activity) {}

  @override
  HomeSnapshotData homeSnapshot(String localDate, {int recentLimit = 10}) =>
      const HomeSnapshotData(
        learningMinutes: 0,
        readingPages: 0,
        masteredWords: 0,
        completedExercises: 0,
        recent: [],
      );

  @override
  void recordCompletedTranslation(CompletedTranslationData translation) {}

  @override
  void dispose() {}
}

class _MemoryImageStore implements ScreenshotTranslationImageStore {
  final Map<String, Uint8List> images = {};
  bool failNextSave = false;
  bool failDelete = false;
  int inspectCalls = 0;

  @override
  Future<void> save(String historyId, Uint8List pngBytes) async {
    if (failNextSave) {
      failNextSave = false;
      throw StateError('simulated image save failure');
    }
    images[historyId] = Uint8List.fromList(pngBytes);
  }

  @override
  Future<Uint8List?> read(String historyId) async => images[historyId];

  @override
  Future<void> delete(String historyId) async {
    if (failDelete) throw StateError('simulated image deletion failure');
    images.remove(historyId);
  }

  @override
  Future<ScreenshotTranslationImageStats> inspect() async {
    inspectCalls++;
    return ScreenshotTranslationImageStats(
      imageCount: images.length,
      totalBytes: images.values.fold(
        0,
        (total, bytes) => total + bytes.lengthInBytes,
      ),
    );
  }

  @override
  Future<void> clearAll() async {
    images.clear();
  }
}

final class _MemoryDictionaryLookupHistoryStore
    implements ScreenshotDictionaryLookupHistoryStore {
  _MemoryDictionaryLookupHistoryStore(this.records);

  final List<ScreenshotDictionaryLookupHistoryRecord> records;

  @override
  Future<List<ScreenshotDictionaryLookupHistoryRecord>> read() async =>
      List.unmodifiable(records);

  @override
  Future<List<ScreenshotDictionaryLookupHistoryRecord>> add(
    ScreenshotDictionaryLookupHistoryRecord record,
  ) async {
    records.insert(0, record);
    if (records.length > screenshotDictionaryLookupHistoryLimit) {
      records.removeRange(
        screenshotDictionaryLookupHistoryLimit,
        records.length,
      );
    }
    return List.unmodifiable(records);
  }

  @override
  Future<List<ScreenshotDictionaryLookupHistoryRecord>> remove(
    String id,
  ) async {
    records.removeWhere((record) => record.id == id);
    return List.unmodifiable(records);
  }

  @override
  Future<List<ScreenshotDictionaryLookupHistoryRecord>> clear() async {
    records.clear();
    return const [];
  }
}

ScreenshotTranslationDesktopController _desktopController({
  Future<void> Function()? onOrbOpen,
  Future<void> Function()? onOrbClose,
  _PreferenceStore? store,
  _HotKeys? hotKeys,
}) => ScreenshotTranslationDesktopController(
  store: store ?? _PreferenceStore(),
  hotKeys: hotKeys ?? _HotKeys(),
  createOrb: () async => _OrbHandle(onOpen: onOrbOpen, onClose: onOrbClose),
  onCapture: () async {},
  onOpenMain: () async {},
  onOpenSettings: () async {},
  onHideMain: () async {},
  onReleaseSession: () async {},
  onCloseChildren: () async {},
  onExit: () async {},
);

class _PreferenceStore implements ScreenshotTranslationPreferencesStore {
  var value = const ScreenshotTranslationPreferences();
  Completer<void>? writeStarted;
  Completer<void>? writeGate;
  @override
  Future<ScreenshotTranslationPreferences> read() async => value;
  @override
  Future<void> write(ScreenshotTranslationPreferences next) async {
    final started = writeStarted;
    if (started != null && !started.isCompleted) started.complete();
    await writeGate?.future;
    value = next;
  }
}

class _HotKeys implements ScreenshotGlobalHotKey {
  ScreenshotHotKey? conflictKey;
  Completer<void>? registerStarted;
  Completer<void>? registerGate;
  Completer<void>? secondRegistrationCompleted;
  Completer<void>? unregisterStarted;
  Completer<void>? unregisterGate;
  final registered = <ScreenshotHotKey>[];

  @override
  Future<void> register(ScreenshotHotKey key, VoidCallback onPressed) async {
    final started = registerStarted;
    if (started != null && !started.isCompleted) started.complete();
    await registerGate?.future;
    registered.add(key);
    final completed = secondRegistrationCompleted;
    if (registered.length >= 2 && completed != null) {
      if (!completed.isCompleted) completed.complete();
    }
    if (key == conflictKey) {
      throw const ScreenshotHotKeyRegistrationException('hotkey_conflict');
    }
  }

  @override
  Future<void> unregister() async {
    final started = unregisterStarted;
    if (started != null && !started.isCompleted) started.complete();
    await unregisterGate?.future;
  }
}

class _OrbHandle implements ScreenshotOrbHandle {
  _OrbHandle({this.onOpen, this.onClose});

  final Future<void> Function()? onOpen;
  final Future<void> Function()? onClose;

  @override
  Future<void> open(ScreenshotOrbPosition? position) async {
    await onOpen?.call();
  }

  @override
  Future<void> close() async => onClose?.call();
}
