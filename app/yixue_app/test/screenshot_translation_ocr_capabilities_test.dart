import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/core/screenshot_translation_capture_service.dart';

void main() {
  group('normalizeScreenshotOcrText', () {
    test('joins spaces inserted between adjacent Chinese characters', () {
      expect(normalizeScreenshotOcrText('这 是 简 体 中 文'), '这是简体中文');
    });

    test('joins spaces around supplementary CJK ideographs', () {
      final first = String.fromCharCode(0x20BB7);
      final second = String.fromCharCode(0x20000);

      expect(normalizeScreenshotOcrText('$first $second'), '$first$second');
    });

    test('preserves spaces between Chinese and Latin text and newlines', () {
      expect(
        normalizeScreenshotOcrText('译 学 Yixue\nRead Codex'),
        '译学 Yixue\nRead Codex',
      );
    });

    test('preserves intentional full-width spacing', () {
      expect(normalizeScreenshotOcrText('中文\u3000内容'), '中文\u3000内容');
    });

    test('removes OCR spaces around Chinese punctuation only', () {
      expect(
        normalizeScreenshotOcrText('中 文 ， 测 试！ 英 语 “ 加 油 ” word spacing'),
        '中文，测试！英语“加油” word spacing',
      );
    });
  });

  group('ScreenshotTranslationOcrCapabilities', () {
    test('recognizes the required English and Simplified Chinese packs', () {
      final capabilities =
          ScreenshotTranslationOcrCapabilities.fromListLanguagesOutput(
            'List of available languages in C:\\Tesseract\\tessdata (3):\n'
            'eng\n'
            'chi_sim\n'
            'osd\n',
          );

      expect(capabilities.engineAvailable, isTrue);
      expect(capabilities.availableLanguages, containsAll(['eng', 'chi_sim']));
      expect(capabilities.isReady, isTrue);
      expect(capabilities.missingLanguageCodes, isEmpty);
    });

    test('ignores a UTF-8 BOM before a language code', () {
      final capabilities =
          ScreenshotTranslationOcrCapabilities.fromListLanguagesOutput(
            'List of available languages (2):\n\uFEFFeng\nchi_sim\n',
          );

      expect(capabilities.isReady, isTrue);
    });

    test('reports a missing required language pack without rejecting OSD', () {
      final capabilities =
          ScreenshotTranslationOcrCapabilities.fromListLanguagesOutput(
            'List of available languages (2):\neng\nosd\n',
          );

      expect(capabilities.engineAvailable, isTrue);
      expect(capabilities.isReady, isFalse);
      expect(capabilities.missingLanguageCodes, {'chi_sim'});
    });

    test('reports that the engine is unavailable', () {
      const capabilities = ScreenshotTranslationOcrCapabilities.unavailable();

      expect(capabilities.engineAvailable, isFalse);
      expect(capabilities.isReady, isFalse);
      expect(capabilities.availableLanguages, isEmpty);
    });

    test(
      'lists languages lazily, caches the result, and supports refresh',
      () async {
        final invocations = <List<String>>[];
        final ocr = ScreenshotTranslationTesseractTextOcr(
          executablePath: 'fake-tesseract.exe',
          processStarter: (_, arguments) async {
            invocations.add(arguments);
            return _ListedLanguagesProcess(
              'List of available languages (2):\neng\nchi_sim\n',
            );
          },
        );

        final first = await ocr.inspectCapabilities();
        final cached = await ocr.inspectCapabilities();
        expect(identical(cached, first), isTrue);
        expect(invocations, hasLength(1));

        final refreshed = await ocr.inspectCapabilities(refresh: true);
        expect(refreshed.isReady, isTrue);
        expect(invocations, hasLength(2));
        expect(invocations, everyElement(['--list-langs']));
      },
    );

    test('bounds language probe startup and stops a late process', () async {
      final pendingStart = Completer<Process>();
      final lateProcess = _ProbeProcess();
      final ocr = ScreenshotTranslationTesseractTextOcr(
        executablePath: 'fake-tesseract.exe',
        processStartTimeout: const Duration(milliseconds: 10),
        processStarter: (_, _) => pendingStart.future,
      );

      final result = await ocr.inspectCapabilities();
      expect(result.checkFailed, isTrue);
      pendingStart.complete(lateProcess);
      await Future<void>.delayed(Duration.zero);

      expect(lateProcess.wasKilled, isTrue);
    });
  });
}

final class _ListedLanguagesProcess implements Process {
  _ListedLanguagesProcess(this.output);

  final String output;
  final _stdin = IOSink(StreamController<List<int>>());

  @override
  int get pid => 1;

  @override
  Future<int> get exitCode => Future<int>.value(0);

  @override
  IOSink get stdin => _stdin;

  @override
  Stream<List<int>> get stdout => Stream<List<int>>.value(utf8.encode(output));

  @override
  Stream<List<int>> get stderr => const Stream<List<int>>.empty();

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => false;
}

final class _ProbeProcess implements Process {
  _ProbeProcess();

  final _stdin = IOSink(StreamController<List<int>>());
  var wasKilled = false;

  @override
  int get pid => 2;

  @override
  Future<int> get exitCode => Future<int>.value(1);

  @override
  IOSink get stdin => _stdin;

  @override
  Stream<List<int>> get stdout => const Stream<List<int>>.empty();

  @override
  Stream<List<int>> get stderr => const Stream<List<int>>.empty();

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    wasKilled = true;
    return true;
  }
}
