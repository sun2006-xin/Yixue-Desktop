import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_screenshot/screenshot.dart';
import 'package:yixue_app/core/screenshot_translation_capture_service.dart';

Future<void> main() async {
  final capability = await ScreenshotTranslationTesseractTextOcr()
      .inspectCapabilities();
  final skipReason = !capability.isReady
      ? 'Local Tesseract OCR is unavailable or missing required language data.'
      : null;

  test('default OCR output cap remains bounded near provider input', () {
    final recognizer = ScreenshotTranslationTesseractTextOcr();

    expect(
      recognizer.maxOutputCharacters,
      screenshotTranslationMaxOcrOutputCharacters,
    );
    expect(
      recognizer.maxOutputCharacters,
      lessThanOrEqualTo(screenshotTranslationMaxSourceCharacters * 4),
    );
    expect(recognizer.pageSegmentationMode, 3);
  });

  test(
    'arbitrary screenshot crops use automatic layout segmentation',
    () async {
      final invocations = <List<String>>[];
      final recognizer = ScreenshotTranslationTesseractTextOcr(
        executablePath: 'fake-tesseract.exe',
        processStarter: (executable, arguments) async {
          invocations.add(arguments);
          await File('${arguments[1]}.txt').writeAsString('captured text');
          return _CompletedProcess();
        },
      );

      await recognizer.recognize(
        Uint8List.fromList(<int>[1, 2, 3]),
        ScreenshotTranslationCancellationToken(),
        sourceLabel: 'multi-block-region.png',
      );

      final arguments = invocations.single;
      final psmIndex = arguments.indexOf('--psm');
      expect(psmIndex, greaterThanOrEqualTo(0));
      expect(arguments[psmIndex + 1], '3');
    },
  );

  test(
    'text-only screenshot OCR recognizes the synthetic local probe',
    () async {
      final bytes = await File(
        'test/fixtures/screenshot_translation_ocr_probe.png',
      ).readAsBytes();
      final result = await ScreenshotTranslationTesseractTextOcr().recognize(
        bytes,
        ScreenshotTranslationCancellationToken(),
        sourceLabel: 'probe.png',
      );

      expect(
        result.toLowerCase(),
        contains('local screenshot translation latency probe'),
      );
    },
    skip: skipReason,
  );

  test(
    'screenshot OCR returns text using one text-only Tesseract process',
    () async {
      final invocations = <List<String>>[];
      final recognizer = ScreenshotTranslationTesseractTextOcr(
        executablePath: 'fake-tesseract.exe',
        processStarter: (executable, arguments) async {
          expect(executable, 'fake-tesseract.exe');
          invocations.add(arguments);
          await File('${arguments[1]}.txt')
              .writeAsString('  captured text  \n');
          return _CompletedProcess();
        },
      );

      final result = await recognizer.recognize(
        Uint8List.fromList(<int>[1, 2, 3]),
        ScreenshotTranslationCancellationToken(),
        sourceLabel: 'sample.png',
      );

      expect(result, 'captured text');
      expect(invocations, hasLength(1));
      expect(invocations.single.last, 'txt');
      expect(invocations.single, isNot(contains('makebox')));
    },
  );

  test('structured OCR requests TSV in one pass and keeps TXT authoritative', () async {
    final invocations = <List<String>>[];
    final recognizer = ScreenshotTranslationTesseractTextOcr(
      executablePath: 'fake-tesseract.exe',
      processStarter: (_, arguments) async {
        invocations.add(arguments);
        await File('${arguments[1]}.txt').writeAsString('captured text');
        await File('${arguments[1]}.tsv').writeAsString('''
level\tpage_num\tblock_num\tpar_num\tline_num\tword_num\tleft\ttop\twidth\theight\tconf\ttext
1\t1\t0\t0\t0\t0\t0\t0\t120\t50\t-1\t
5\t1\t1\t1\t1\t1\t10\t12\t40\t15\t95.0\tcaptured
5\t1\t1\t1\t1\t2\t56\t12\t40\t15\t90.0\ttext
''');
        return _CompletedProcess();
      },
    );

    final document = await recognizer.recognizeDocument(
      Uint8List.fromList(<int>[1, 2, 3]),
      ScreenshotTranslationCancellationToken(),
      sourceLabel: 'sample.png',
    );

    expect(document.text, 'captured text');
    expect(document.layout?.blocks.single.text, 'captured text');
    expect(document.layout?.imageWidth, 120);
    expect(invocations, hasLength(1));
    expect(invocations.single, containsAll(<String>['txt', 'tessedit_create_tsv=1']));
  });

  test('missing or malformed optional TSV does not discard valid TXT', () async {
    for (final emitTsv in <bool>[false, true]) {
      final recognizer = ScreenshotTranslationTesseractTextOcr(
        executablePath: 'fake-tesseract.exe',
        processStarter: (_, arguments) async {
          await File('${arguments[1]}.txt').writeAsString('valid text');
          if (emitTsv) {
            await File('${arguments[1]}.tsv').writeAsString('bad tsv');
          }
          return _CompletedProcess();
        },
      );

      final document = await recognizer.recognizeDocument(
        Uint8List.fromList(<int>[1]),
        ScreenshotTranslationCancellationToken(),
      );

      expect(document.text, 'valid text');
      expect(document.layout, isNull);
    }
  });

  test('capture dimensions must match TSV page dimensions or boxes are dropped', () async {
    final recognizer = ScreenshotTranslationTesseractTextOcr(
      executablePath: 'fake-tesseract.exe',
      processStarter: (_, arguments) async {
        await File('${arguments[1]}.txt').writeAsString('captured text');
        await File('${arguments[1]}.tsv').writeAsString('''
level\tpage_num\tblock_num\tpar_num\tline_num\tword_num\tleft\ttop\twidth\theight\tconf\ttext
1\t1\t0\t0\t0\t0\t0\t0\t120\t50\t-1\t
5\t1\t1\t1\t1\t1\t10\t12\t40\t15\t95.0\tcaptured
5\t1\t1\t1\t1\t2\t56\t12\t40\t15\t90.0\ttext
''');
        return _CompletedProcess();
      },
    );
    final service = ScreenshotTranslationCaptureService(textOcr: recognizer);

    final document = await service.recognizeDocument(
      CapturedData(
        width: 121,
        height: 50,
        bytes: Uint8List.fromList(<int>[1, 2]),
        left: 0,
      ),
    );

    expect(document.text, 'captured text');
    expect(document.layout, isNull);
  });

  test('cancelled screenshot OCR does not start a Tesseract process', () async {
    var processStarts = 0;
    final recognizer = ScreenshotTranslationTesseractTextOcr(
      executablePath: 'fake-tesseract.exe',
      processStarter: (_, _) async {
        processStarts++;
        return _CompletedProcess();
      },
    );
    final token = ScreenshotTranslationCancellationToken()
      ..cancel('cancel before OCR');

    await expectLater(
      recognizer.recognize(
        Uint8List.fromList(<int>[1]),
        token,
        sourceLabel: 'sample.png',
      ),
      throwsA(isA<ScreenshotTranslationCancelledException>()),
    );

    expect(processStarts, 0);
  });

  test(
    'cancellation while Tesseract is starting returns and kills a late process',
    () async {
      final pendingStart = Completer<Process>();
      final startRequested = Completer<void>();
      final lateProcess = _HangingProcess();
      final token = ScreenshotTranslationCancellationToken();
      final recognizer = ScreenshotTranslationTesseractTextOcr(
        executablePath: 'fake-tesseract.exe',
        processStartTimeout: const Duration(seconds: 2),
        processStarter: (_, _) {
          startRequested.complete();
          return pendingStart.future;
        },
      );

      final recognition = recognizer.recognize(
        Uint8List.fromList(<int>[1]),
        token,
        sourceLabel: 'starting.png',
      );
      await startRequested.future;
      token.cancel('cancel while process is starting');

      await expectLater(
        recognition,
        throwsA(isA<ScreenshotTranslationCancelledException>()),
      );
      pendingStart.complete(lateProcess);
      await Future<void>.delayed(Duration.zero);

      expect(lateProcess.wasKilled, isTrue);
    },
  );

  test(
    'Tesseract process startup timeout returns the OCR timeout code',
    () async {
      final pendingStart = Completer<Process>();
      final lateProcess = _HangingProcess();
      final recognizer = ScreenshotTranslationTesseractTextOcr(
        executablePath: 'fake-tesseract.exe',
        processStartTimeout: const Duration(milliseconds: 10),
        processStarter: (_, _) => pendingStart.future,
      );

      await expectLater(
        recognizer.recognize(
          Uint8List.fromList(<int>[1]),
          ScreenshotTranslationCancellationToken(),
          sourceLabel: 'startup-timeout.png',
        ),
        throwsA(
          isA<ScreenshotTranslationOcrException>().having(
            (error) => error.code,
            'code',
            'ocr_timeout',
          ),
        ),
      );
      pendingStart.complete(lateProcess);
      await Future<void>.delayed(Duration.zero);

      expect(lateProcess.wasKilled, isTrue);
    },
  );

  test(
    'screenshot OCR returns actionable timeout and output-limit codes',
    () async {
      final hangingProcess = _HangingProcess();
      final timeoutRecognizer = ScreenshotTranslationTesseractTextOcr(
        executablePath: 'fake-tesseract.exe',
        timeout: const Duration(milliseconds: 10),
        processStarter: (_, _) async => hangingProcess,
      );
      await expectLater(
        timeoutRecognizer.recognize(
          Uint8List.fromList(<int>[1]),
          ScreenshotTranslationCancellationToken(),
          sourceLabel: 'timeout.png',
        ),
        throwsA(
          isA<ScreenshotTranslationOcrException>().having(
            (error) => error.code,
            'code',
            'ocr_timeout',
          ),
        ),
      );
      expect(hangingProcess.wasKilled, isTrue);

      final outputLimitRecognizer = ScreenshotTranslationTesseractTextOcr(
        executablePath: 'fake-tesseract.exe',
        maxOutputCharacters: 2,
        processStarter: (_, arguments) async {
          await File('${arguments[1]}.txt').writeAsString('long');
          return _CompletedProcess();
        },
      );
      await expectLater(
        outputLimitRecognizer.recognize(
          Uint8List.fromList(<int>[1]),
          ScreenshotTranslationCancellationToken(),
          sourceLabel: 'large.png',
        ),
        throwsA(
          isA<ScreenshotTranslationOcrException>().having(
            (error) => error.code,
            'code',
            'ocr_output_limit',
          ),
        ),
      );
    },
  );

  test(
    'Tesseract process failures and malformed output use the OCR error code',
    () async {
      final failedProcessRecognizer = ScreenshotTranslationTesseractTextOcr(
        executablePath: 'fake-tesseract.exe',
        processStarter: (_, _) async =>
            _CompletedProcess(returnCode: 1, stderrBytes: const <int>[0xFF]),
      );
      await expectLater(
        failedProcessRecognizer.recognize(
          Uint8List.fromList(<int>[1]),
          ScreenshotTranslationCancellationToken(),
          sourceLabel: 'failed.png',
        ),
        throwsA(
          isA<ScreenshotTranslationOcrException>().having(
            (error) => error.code,
            'code',
            'ocr_failed',
          ),
        ),
      );

      final malformedTextRecognizer = ScreenshotTranslationTesseractTextOcr(
        executablePath: 'fake-tesseract.exe',
        processStarter: (_, arguments) async {
          await File('${arguments[1]}.txt').writeAsBytes(const <int>[0xFF]);
          return _CompletedProcess();
        },
      );
      await expectLater(
        malformedTextRecognizer.recognize(
          Uint8List.fromList(<int>[1]),
          ScreenshotTranslationCancellationToken(),
          sourceLabel: 'malformed.png',
        ),
        throwsA(
          isA<ScreenshotTranslationOcrException>().having(
            (error) => error.code,
            'code',
            'ocr_failed',
          ),
        ),
      );
    },
  );

  test('missing local OCR executable reports the unavailable code', () async {
    final recognizer = ScreenshotTranslationTesseractTextOcr(
      executablePath: 'missing-tesseract.exe',
      processStarter: (_, _) async =>
          throw ProcessException('missing-tesseract.exe', const <String>[]),
    );

    await expectLater(
      recognizer.recognize(
        Uint8List.fromList(<int>[1]),
        ScreenshotTranslationCancellationToken(),
        sourceLabel: 'unavailable.png',
      ),
      throwsA(
        isA<ScreenshotTranslationOcrException>().having(
          (error) => error.code,
          'code',
          'ocr_unavailable',
        ),
      ),
    );
  });
}

final class _CompletedProcess implements Process {
  _CompletedProcess({this.returnCode = 0, this.stderrBytes = const <int>[]});

  final int returnCode;
  final List<int> stderrBytes;
  final _stdin = IOSink(StreamController<List<int>>());

  @override
  int get pid => 1;

  @override
  Future<int> get exitCode => Future<int>.value(returnCode);

  @override
  IOSink get stdin => _stdin;

  @override
  Stream<List<int>> get stdout => const Stream<List<int>>.empty();

  @override
  Stream<List<int>> get stderr => stderrBytes.isEmpty
      ? const Stream<List<int>>.empty()
      : Stream<List<int>>.value(stderrBytes);

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => false;
}

final class _HangingProcess implements Process {
  final _exitCode = Completer<int>();
  final _stdout = StreamController<List<int>>();
  final _stderr = StreamController<List<int>>();
  final _stdinController = StreamController<List<int>>();
  late final _stdin = IOSink(_stdinController);
  var wasKilled = false;

  @override
  int get pid => 2;

  @override
  Future<int> get exitCode => _exitCode.future;

  @override
  IOSink get stdin => _stdin;

  @override
  Stream<List<int>> get stdout => _stdout.stream;

  @override
  Stream<List<int>> get stderr => _stderr.stream;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    wasKilled = true;
    if (!_exitCode.isCompleted) _exitCode.complete(1);
    unawaited(_stdout.close());
    unawaited(_stderr.close());
    unawaited(_stdin.close());
    return true;
  }
}
