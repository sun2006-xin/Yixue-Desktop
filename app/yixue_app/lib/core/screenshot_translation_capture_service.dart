import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:just_screenshot/screenshot.dart';
import 'package:yixue_app/core/screenshot_translation_ocr_layout.dart';

/// Maximum text that can reach the screenshot translation provider.
const screenshotTranslationMaxSourceCharacters = 5000;

/// Allows room for Tesseract's extra spaces between adjacent Han characters,
/// while keeping intermediate OCR output bounded well below provider input.
const screenshotTranslationMaxOcrOutputCharacters =
    screenshotTranslationMaxSourceCharacters * 4;

final class ScreenshotTranslationCapture {
  const ScreenshotTranslationCapture({
    required this.imageBytes,
    required this.bounds,
    required this.recognizedText,
  });

  final Uint8List imageBytes;
  final ScreenshotBounds bounds;
  int get width => bounds.width;
  int get height => bounds.height;
  final String recognizedText;
}

typedef ScreenshotTranslationOcrProcessStarter = Future<Process> Function(
  String executable,
  List<String> arguments,
);

/// Cancellation state owned by Yixue's screenshot translation OCR flow.
final class ScreenshotTranslationCancellationToken {
  final Completer<void> _cancelled = Completer<void>();
  String? _reason;

  bool get isCancelled => _cancelled.isCompleted;
  Future<void> get whenCancelled => _cancelled.future;
  String? get reason => _reason;

  void cancel([String? reason]) {
    if (isCancelled) return;
    _reason = reason;
    _cancelled.complete();
  }

  void throwIfCancelled() {
    if (isCancelled) {
      throw ScreenshotTranslationCancelledException(reason ?? 'OCR 已取消');
    }
  }
}

final class ScreenshotTranslationCancelledException implements Exception {
  const ScreenshotTranslationCancelledException([this.message = 'OCR 已取消']);

  final String message;

  @override
  String toString() => message;
}

final class ScreenshotTranslationOcrException implements Exception {
  const ScreenshotTranslationOcrException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
}

final class ScreenshotTranslationOcrCapabilities {
  const ScreenshotTranslationOcrCapabilities({
    required this.engineAvailable,
    this.availableLanguages = const {},
    this.checkFailed = false,
  });

  const ScreenshotTranslationOcrCapabilities.unavailable()
    : engineAvailable = false,
      availableLanguages = const {},
      checkFailed = false;

  const ScreenshotTranslationOcrCapabilities.probeFailed()
    : engineAvailable = false,
      availableLanguages = const {},
      checkFailed = true;

  final bool engineAvailable;
  final Set<String> availableLanguages;
  final bool checkFailed;

  Set<String> get missingLanguageCodes => Set.unmodifiable(<String>{
    if (!availableLanguages.contains('eng')) 'eng',
    if (!availableLanguages.contains('chi_sim')) 'chi_sim',
  });

  bool get isReady =>
      engineAvailable && !checkFailed && missingLanguageCodes.isEmpty;

  String get statusMessage {
    if (checkFailed) return '无法读取本机 OCR 语言包状态';
    if (!engineAvailable) return '未找到本机 Tesseract OCR';
    final missing = missingLanguageCodes;
    if (missing.isEmpty) return '离线 OCR 已就绪 · 英语与简体中文';
    final labels = <String>[
      if (missing.contains('eng')) '英语（eng）',
      if (missing.contains('chi_sim')) '简体中文（chi_sim）',
    ];
    return 'OCR 语言包缺少${labels.join('、')}';
  }

  String get guidance {
    if (checkFailed) return '请检查 Tesseract 安装和语言数据目录后重新检查。';
    if (!engineAvailable) return '请安装 Tesseract OCR，或配置本机 OCR 可执行文件。';
    if (missingLanguageCodes.isNotEmpty) {
      return '请为当前 Tesseract 安装英语（eng）和简体中文（chi_sim）语言包。';
    }
    return '截图在本机识别；识别完成后自动判断英译中或中译英。';
  }

  factory ScreenshotTranslationOcrCapabilities.fromListLanguagesOutput(
    String output,
  ) {
    final languages = output
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim().replaceFirst('\uFEFF', ''))
        .where((line) => RegExp(r'^[A-Za-z0-9_]+$').hasMatch(line))
        .toSet();
    return ScreenshotTranslationOcrCapabilities(
      engineAvailable: true,
      availableLanguages: Set.unmodifiable(languages),
    );
  }
}

typedef ScreenshotTranslationOcrInspector =
    Future<ScreenshotTranslationOcrCapabilities> Function({bool refresh});

/// Returns whether [codePoint] is a CJK unified or compatibility ideograph.
///
/// Supplementary-plane ranges follow Unicode 17.0.0 `Scripts.txt`.
bool isScreenshotTranslationHanIdeograph(int codePoint) =>
    (codePoint >= 0x3400 && codePoint <= 0x4DBF) ||
    (codePoint >= 0x4E00 && codePoint <= 0x9FFF) ||
    (codePoint >= 0xF900 && codePoint <= 0xFA6D) ||
    (codePoint >= 0xFA70 && codePoint <= 0xFAD9) ||
    (codePoint >= 0x20000 && codePoint <= 0x2A6DF) ||
    (codePoint >= 0x2A700 && codePoint <= 0x2B81D) ||
    (codePoint >= 0x2B820 && codePoint <= 0x2CEAD) ||
    (codePoint >= 0x2CEB0 && codePoint <= 0x2EBE0) ||
    (codePoint >= 0x2EBF0 && codePoint <= 0x2EE5D) ||
    (codePoint >= 0x2F800 && codePoint <= 0x2FA1D) ||
    (codePoint >= 0x30000 && codePoint <= 0x3134A) ||
    (codePoint >= 0x31350 && codePoint <= 0x33479);

int _codePointAt(String text, int index) {
  final first = text.codeUnitAt(index);
  if (first < 0xD800 || first > 0xDBFF || index + 1 >= text.length) {
    return first;
  }
  final second = text.codeUnitAt(index + 1);
  if (second < 0xDC00 || second > 0xDFFF) return first;
  return 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00);
}

int _codePointBefore(String text, int index) {
  final last = text.codeUnitAt(index - 1);
  if (last < 0xDC00 || last > 0xDFFF || index < 2) return last;
  final first = text.codeUnitAt(index - 2);
  if (first < 0xD800 || first > 0xDBFF) return last;
  return 0x10000 + ((first - 0xD800) << 10) + (last - 0xDC00);
}

Future<Process> _awaitProcessStart(
  Future<Process> pendingStart,
  Duration timeout, {
  ScreenshotTranslationCancellationToken? cancellationToken,
}) async {
  try {
    final timedStart = pendingStart.timeout(timeout);
    if (cancellationToken == null) return await timedStart;
    return await Future.any<Process>(<Future<Process>>[
      timedStart,
      cancellationToken.whenCancelled.then<Process>(
        (_) => throw ScreenshotTranslationCancelledException(
          cancellationToken.reason ?? 'OCR 已取消',
        ),
      ),
    ]);
  } on TimeoutException {
    _stopProcessWhenReady(pendingStart);
    rethrow;
  } on ScreenshotTranslationCancelledException {
    _stopProcessWhenReady(pendingStart);
    rethrow;
  }
}

void _stopProcessWhenReady(Future<Process> pendingStart) {
  final cleanup = pendingStart.then<void>(
    (process) => _terminateLateProcess(process),
    onError: (Object _, StackTrace _) {},
  );
  unawaited(cleanup.catchError((Object _) {}));
}

Future<void> _terminateLateProcess(Process process) async {
  final drains = <Future<void>>[];
  try {
    drains.add(_ignoreStream(process.stdout));
  } on Object {
    // Continue killing the process even if a fake or host stream throws.
  }
  try {
    drains.add(_ignoreStream(process.stderr));
  } on Object {
    // Continue killing the process even if a fake or host stream throws.
  }
  try {
    drains.add(_ignoreFuture(process.exitCode));
  } on Object {
    // A process with an invalid exit-code handle is still best-effort killed.
  }
  try {
    process.kill();
  } on Object {
    // A late process must not make the cancelled OCR request wait again.
  }
  try {
    await Future.wait<void>(drains).timeout(const Duration(seconds: 3));
  } on Object {
    // Reaping remains bounded even if a process host never closes its streams.
  }
}

Future<void> _ignoreStream(Stream<List<int>> stream) async {
  try {
    await stream.drain<void>();
  } on Object {
    // Stream cleanup errors are irrelevant after the owning OCR was cancelled.
  }
}

Future<void> _ignoreFuture<T>(Future<T> future) async {
  try {
    await future;
  } on Object {
    // Observe late process completion without surfacing background errors.
  }
}

bool _isCjkPunctuation(int codePoint) => const <int>{
  0x2014, // —
  0x2018, // ‘
  0x2019, // ’
  0x201C, // “
  0x201D, // ”
  0x2026, // …
  0x3001, // 、
  0x3002, // 。
  0x3008, // 〈
  0x3009, // 〉
  0x300A, // 《
  0x300B, // 》
  0x300C, // 「
  0x300D, // 」
  0x300E, // 『
  0x300F, // 』
  0x3010, // 【
  0x3011, // 】
  0x3014, // 〔
  0x3015, // 〕
  0x3016, // 〖
  0x3017, // 〗
  0x3018, // 〘
  0x3019, // 〙
  0x301A, // 〚
  0x301B, // 〛
  0x30FB, // ・
  0xFF08, // （
  0xFF09, // ）
  0xFF3B, // ［
  0xFF3D, // ］
  0xFF0C, // ，
  0xFF0E, // ．
  0xFF1A, // ：
  0xFF1B, // ；
  0xFF1F, // ？
  0xFF01, // ！
  0xFF5B, // ｛
  0xFF5D, // ｝
}.contains(codePoint);

/// Removes spacing Tesseract can insert between adjacent Chinese characters.
/// Spaces between scripts and explicit line breaks remain unchanged.
String normalizeScreenshotOcrText(String text) {
  bool isHorizontalSpace(int codeUnit) =>
      codeUnit == 0x09 || codeUnit == 0x20 || codeUnit == 0xA0;

  final normalized = StringBuffer();
  var index = 0;
  while (index < text.length) {
    final current = text.codeUnitAt(index);
    if (!isHorizontalSpace(current)) {
      normalized.write(text[index]);
      index++;
      continue;
    }

    final whitespaceStart = index;
    while (index < text.length && isHorizontalSpace(text.codeUnitAt(index))) {
      index++;
    }
    final previousIsHan =
        whitespaceStart > 0 &&
        isScreenshotTranslationHanIdeograph(
          _codePointBefore(text, whitespaceStart),
        );
    final nextIsHan =
        index < text.length &&
        isScreenshotTranslationHanIdeograph(_codePointAt(text, index));
    final previousIsCjkPunctuation =
        whitespaceStart > 0 &&
        _isCjkPunctuation(_codePointBefore(text, whitespaceStart));
    final nextIsCjkPunctuation =
        index < text.length && _isCjkPunctuation(_codePointAt(text, index));
    final joinsCjkText =
        (previousIsHan || previousIsCjkPunctuation) &&
        (nextIsHan || nextIsCjkPunctuation);
    if (!joinsCjkText) {
      normalized.write(text.substring(whitespaceStart, index));
    }
  }
  return normalized.toString().trim();
}

/// Runs only Tesseract's text pass; screenshot translation has no use for the
/// reader's optional per-character boxes.
final class ScreenshotTranslationTesseractTextOcr {
  ScreenshotTranslationTesseractTextOcr({
    this.executablePath,
    this.languages = 'eng+chi_sim',
    // Screenshot regions are arbitrary crops and may contain multiple text
    // blocks or columns. Automatic segmentation handles that shape better
    // than assuming one uniform block; callers may still select a narrower
    // page mode when they have a known single-block crop.
    this.pageSegmentationMode = 3,
    this.timeout = const Duration(seconds: 45),
    this.processStartTimeout = const Duration(seconds: 10),
    this.maxOutputCharacters = screenshotTranslationMaxOcrOutputCharacters,
    ScreenshotTranslationOcrProcessStarter? processStarter,
  }) : _processStarter = processStarter ?? Process.start;

  final String? executablePath;
  final String languages;
  final int pageSegmentationMode;
  final Duration timeout;
  final Duration processStartTimeout;
  final int maxOutputCharacters;
  final ScreenshotTranslationOcrProcessStarter _processStarter;
  Future<String?>? _resolvedExecutable;
  Future<ScreenshotTranslationOcrCapabilities>? _capabilityCheck;

  Future<ScreenshotTranslationOcrCapabilities> inspectCapabilities({
    bool refresh = false,
  }) {
    if (refresh) _capabilityCheck = null;
    return _capabilityCheck ??= _readCapabilities();
  }

  Future<ScreenshotTranslationOcrCapabilities> _readCapabilities() async {
    final String? executable;
    try {
      executable = await _resolveExecutable();
    } on Object {
      return const ScreenshotTranslationOcrCapabilities.probeFailed();
    }
    if (executable == null) {
      return const ScreenshotTranslationOcrCapabilities.unavailable();
    }

    Process? process;
    Future<int>? exitCode;
    Future<String>? stdout;
    Future<String>? stderr;
    try {
      final child = await _startProcess(executable, const ['--list-langs']);
      process = child;
      final childExitCode = child.exitCode;
      final childStdout = child.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .join();
      final childStderr = child.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .join();
      exitCode = childExitCode;
      stdout = childStdout;
      stderr = childStderr;
      final code = await childExitCode.timeout(const Duration(seconds: 4));
      final output = await Future.wait<String>([childStdout, childStderr])
          .timeout(const Duration(seconds: 2));
      if (code != 0) {
        return const ScreenshotTranslationOcrCapabilities.probeFailed();
      }
      return ScreenshotTranslationOcrCapabilities.fromListLanguagesOutput(
        output[0],
      );
    } on TimeoutException {
      if (process != null &&
          exitCode != null &&
          stdout != null &&
          stderr != null) {
        await _stopAndDrain(process, exitCode, stdout, stderr);
      }
      return const ScreenshotTranslationOcrCapabilities.probeFailed();
    } on Object {
      if (process != null &&
          exitCode != null &&
          stdout != null &&
          stderr != null) {
        await _stopAndDrain(process, exitCode, stdout, stderr);
      }
      return const ScreenshotTranslationOcrCapabilities.probeFailed();
    }
  }

  Future<String> recognize(
    Uint8List bytes,
    ScreenshotTranslationCancellationToken cancellationToken, {
    String sourceLabel = 'screenshot.png',
  }) async => (await _recognizeDocument(
    bytes,
    cancellationToken,
    sourceLabel: sourceLabel,
    includeLayout: false,
  )).text;

  /// Runs the same OCR pass as [recognize] and requests TSV layout in that
  /// process. A missing or malformed TSV only removes the optional boxes.
  Future<ScreenshotTranslationOcrDocument> recognizeDocument(
    Uint8List bytes,
    ScreenshotTranslationCancellationToken cancellationToken, {
    String sourceLabel = 'screenshot.png',
  }) => _recognizeDocument(
    bytes,
    cancellationToken,
    sourceLabel: sourceLabel,
    includeLayout: true,
  );

  Future<ScreenshotTranslationOcrDocument> _recognizeDocument(
    Uint8List bytes,
    ScreenshotTranslationCancellationToken cancellationToken, {
    required String sourceLabel,
    required bool includeLayout,
  }) async {
    cancellationToken.throwIfCancelled();
    if (bytes.isEmpty) {
      throw const ScreenshotTranslationOcrException(
        'capture_failed',
        'OCR 输入图片为空',
      );
    }
    if (languages.trim().isEmpty) {
      throw const ScreenshotTranslationOcrException(
        'ocr_unavailable',
        'OCR 语言包配置为空',
      );
    }

    final executable = await _resolveExecutable();
    if (executable == null) {
      throw const ScreenshotTranslationOcrException(
        'ocr_unavailable',
        '本机未找到离线 Tesseract 引擎',
      );
    }

    final temporary = await Directory.systemTemp.createTemp(
      'yixue-screenshot-ocr-',
    );
    final input = File(
      '${temporary.path}${Platform.pathSeparator}capture${_imageExtension(sourceLabel)}',
    );
    final outputBase = '${temporary.path}${Platform.pathSeparator}result';
    try {
      // Tesseract reads this disposable input immediately; durable flush is
      // only needed for persistent image storage, not this temporary file.
      await input.writeAsBytes(bytes);
      cancellationToken.throwIfCancelled();
      final Process process;
      try {
        process = await _startProcess(executable, <String>[
          input.path,
          outputBase,
          '-l',
          languages,
          '--psm',
          '$pageSegmentationMode',
          if (includeLayout) ...<String>['-c', 'tessedit_create_tsv=1'],
          'txt',
        ], cancellationToken: cancellationToken);
      } on TimeoutException {
        throw const ScreenshotTranslationOcrException(
          'ocr_timeout',
          'OCR 引擎启动超时，已取消',
        );
      }
      const diagnosticDecoder = Utf8Decoder(allowMalformed: true);
      final stdout = process.stdout.transform(diagnosticDecoder).join();
      final stderr = process.stderr.transform(diagnosticDecoder).join();
      final exitCodeFuture = process.exitCode;
      int? exitCode;
      try {
        exitCode = await Future.any<int?>(<Future<int?>>[
          exitCodeFuture.then<int?>((code) => code),
          cancellationToken.whenCancelled.then<int?>((_) => null),
        ]).timeout(timeout);
      } on TimeoutException {
        await _stopAndDrain(process, exitCodeFuture, stdout, stderr);
        throw const ScreenshotTranslationOcrException(
          'ocr_timeout',
          'OCR 页面处理超时，已取消',
        );
      }
      if (exitCode == null) {
        await _stopAndDrain(process, exitCodeFuture, stdout, stderr);
        throw ScreenshotTranslationCancelledException(
          cancellationToken.reason ?? 'OCR 已取消',
        );
      }

      final output = await Future.wait<String>(<Future<String>>[
        stdout,
        stderr,
      ]);
      if (exitCode != 0) {
        final details = output[1].trim().isEmpty
            ? output[0].trim()
            : output[1].trim();
        throw ScreenshotTranslationOcrException(
          'ocr_failed',
          details.isEmpty ? 'Tesseract 处理失败（退出码 $exitCode）' : details,
        );
      }
      final resultFile = File('$outputBase.txt');
      if (!await resultFile.exists()) {
        throw const ScreenshotTranslationOcrException(
          'ocr_failed',
          'OCR 引擎没有生成文本层',
        );
      }
      if (await resultFile.length() > maxOutputCharacters * 4) {
        throw const ScreenshotTranslationOcrException(
          'ocr_output_limit',
          'OCR 文本超过单页输出上限',
        );
      }
      cancellationToken.throwIfCancelled();
      final String text;
      try {
        text = utf8.decode(await resultFile.readAsBytes());
      } on FormatException {
        throw const ScreenshotTranslationOcrException(
          'ocr_failed',
          'OCR 输出不是有效的 UTF-8 文本',
        );
      }
      if (text.length > maxOutputCharacters) {
        throw const ScreenshotTranslationOcrException(
          'ocr_output_limit',
          'OCR 文本超过单页输出上限',
        );
      }
      cancellationToken.throwIfCancelled();
      final normalizedText = normalizeScreenshotOcrText(text);
      ScreenshotTranslationOcrLayout? layout;
      if (includeLayout) {
        final tsvFile = File('$outputBase.tsv');
        try {
          if (await tsvFile.exists() &&
              await tsvFile.length() <= screenshotTranslationMaxTsvCharacters) {
            final tsv = utf8.decode(await tsvFile.readAsBytes());
            layout = parseScreenshotTranslationTesseractTsv(tsv);
          }
        } on FormatException {
          // Layout is optional; malformed TSV must not discard valid OCR text.
        } on FileSystemException {
          // A race deleting the temporary output has the same safe fallback.
        } on Object {
          // Unexpected optional-parser errors also retain the valid TXT result.
        }
      }
      cancellationToken.throwIfCancelled();
      return ScreenshotTranslationOcrDocument(
        text: normalizedText,
        layout: layout,
      );
    } on ScreenshotTranslationOcrException {
      rethrow;
    } on ScreenshotTranslationCancelledException {
      rethrow;
    } on ProcessException catch (error) {
      throw ScreenshotTranslationOcrException(
        'ocr_unavailable',
        '无法启动离线 OCR：${error.message}',
      );
    } finally {
      if (await temporary.exists()) await temporary.delete(recursive: true);
    }
  }

  Future<String?> _resolveExecutable() async {
    if (executablePath != null && executablePath!.trim().isNotEmpty) {
      return executablePath!.trim();
    }
    final cached = _resolvedExecutable;
    if (cached != null) return cached;

    final pending = _findExecutable();
    _resolvedExecutable = pending;
    try {
      final executable = await pending;
      if (executable == null && identical(_resolvedExecutable, pending)) {
        _resolvedExecutable = null;
      }
      return executable;
    } catch (_) {
      if (identical(_resolvedExecutable, pending)) {
        _resolvedExecutable = null;
      }
      rethrow;
    }
  }

  Future<Process> _startProcess(
    String executable,
    List<String> arguments, {
    ScreenshotTranslationCancellationToken? cancellationToken,
  }) => _awaitProcessStart(
    _processStarter(executable, arguments),
    processStartTimeout,
    cancellationToken: cancellationToken,
  );

  Future<String?> _findExecutable() async {
    final candidates = <String>[
      if (Platform.environment['TESSERACT_EXE'] case final configured?
          when configured.trim().isNotEmpty)
        configured.trim(),
      if (Platform.isWindows) ...<String>[
        for (final root in <String>{
          Directory.current.path,
          File(Platform.resolvedExecutable).parent.path,
          if (Platform.environment['ZHILUME_TESSERACT_HOME']
              case final configured? when configured.trim().isNotEmpty)
            configured.trim(),
        }) ...<String>[
          '$root${Platform.pathSeparator}ocr${Platform.pathSeparator}tesseract${Platform.pathSeparator}tesseract.exe',
          '$root${Platform.pathSeparator}tesseract${Platform.pathSeparator}tesseract.exe',
        ],
        r'C:\Program Files\Tesseract-OCR\tesseract.exe',
        r'C:\Program Files (x86)\Tesseract-OCR\tesseract.exe',
      ],
      if (!Platform.isWindows) 'tesseract',
    ];
    for (final candidate in candidates) {
      if (candidate == 'tesseract') return candidate;
      if (await File(candidate).exists()) return candidate;
    }
    if (Platform.isWindows) {
      final path = await _findWindowsPathExecutable();
      if (path != null) return path;
    }
    return null;
  }

  Future<String?> _findWindowsPathExecutable() async {
    Process? process;
    Future<int>? exitCode;
    Future<String>? stdout;
    Future<String>? stderr;
    try {
      final child = await _awaitProcessStart(
        Process.start('where.exe', <String>['tesseract.exe']),
        processStartTimeout,
      );
      process = child;
      final childExitCode = child.exitCode;
      final childStdout = child.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .join();
      final childStderr = child.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .join();
      exitCode = childExitCode;
      stdout = childStdout;
      stderr = childStderr;
      final code = await childExitCode.timeout(const Duration(seconds: 2));
      final output = await Future.wait<String>([childStdout, childStderr])
          .timeout(const Duration(seconds: 2));
      if (code != 0) return null;
      final path = output[0]
          .split(RegExp(r'\r?\n'))
          .map((line) => line.trim())
          .firstWhere((line) => line.isNotEmpty, orElse: () => '');
      return path.isEmpty ? null : path;
    } on Object {
      if (process != null &&
          exitCode != null &&
          stdout != null &&
          stderr != null) {
        await _stopAndDrain(process, exitCode, stdout, stderr);
      }
      // Missing PATH lookup does not block configured install locations.
      return null;
    }
  }

  Future<void> _stopAndDrain(
    Process process,
    Future<int> exitCode,
    Future<String> stdout,
    Future<String> stderr,
  ) async {
    try {
      process.kill();
    } on Object {
      // Continue draining and release the temporary input even if kill fails.
    }
    try {
      await Future.wait<void>(<Future<void>>[
        exitCode.then<void>((_) {}),
        stdout.then<void>((_) {}),
        stderr.then<void>((_) {}),
      ]).timeout(const Duration(seconds: 3));
    } on Object {
      // Keep process reaping bounded if Windows does not report exit.
    }
  }

  String _imageExtension(String sourceLabel) {
    final lower = sourceLabel.toLowerCase();
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return '.jpg';
    if (lower.endsWith('.webp')) return '.webp';
    if (lower.endsWith('.ppm')) return '.ppm';
    return '.png';
  }
}

final class ScreenshotTranslationCaptureService {
  ScreenshotTranslationCaptureService({
    ScreenshotTranslationTesseractTextOcr? textOcr,
  }) : _textOcr = textOcr ?? ScreenshotTranslationTesseractTextOcr();

  final ScreenshotTranslationTesseractTextOcr _textOcr;

  Future<ScreenshotTranslationOcrCapabilities> inspectOcrCapabilities({
    bool refresh = false,
  }) => _textOcr.inspectCapabilities(refresh: refresh);

  Future<ScreenshotTranslationCapture?> captureAndRecognize() async {
    final capture = await captureRegion();
    if (capture == null) return null;
    return ScreenshotTranslationCapture(
      imageBytes: capture.bytes,
      bounds: capture.bounds,
      recognizedText: await recognize(capture),
    );
  }

  Future<CapturedData?> captureRegion() async {
    if (!Platform.isWindows) {
      throw const ScreenshotTranslationCaptureException(
        '截屏翻译当前仅支持 Windows 桌面版',
      );
    }

    final capture = await Screenshot.instance.capture(
      mode: ScreenshotMode.region,
    );
    if (capture == null) return null;
    if (capture.bytes.isEmpty || capture.width < 1 || capture.height < 1) {
      throw const ScreenshotTranslationCaptureException('截屏结果为空，请重新选择区域');
    }

    return capture;
  }

  Future<CapturedData?> captureAtBounds(ScreenshotBounds bounds) async {
    if (!Platform.isWindows) {
      throw const ScreenshotTranslationCaptureException(
        '固定区域截图当前仅支持 Windows 桌面版',
      );
    }
    final capture = await Screenshot.instance.captureAtBounds(bounds);
    if (capture == null ||
        capture.bytes.isEmpty ||
        capture.width < 1 ||
        capture.height < 1) {
      throw const ScreenshotTranslationCaptureException('固定区域已失效，请重新框选并固定区域。');
    }
    return capture;
  }

  Future<String> recognize(
    CapturedData capture, [
    ScreenshotTranslationCancellationToken? cancellationToken,
  ]) async {
    return _textOcr.recognize(
      capture.bytes,
      cancellationToken ?? ScreenshotTranslationCancellationToken(),
      sourceLabel: 'screenshot-translation.png',
    );
  }

  Future<ScreenshotTranslationOcrDocument> recognizeDocument(
    CapturedData capture, [
    ScreenshotTranslationCancellationToken? cancellationToken,
  ]) async {
    final document = await _textOcr.recognizeDocument(
      capture.bytes,
      cancellationToken ?? ScreenshotTranslationCancellationToken(),
      sourceLabel: 'screenshot-translation.png',
    );
    final layout = document.layout;
    if (layout == null ||
        (layout.imageWidth == capture.width &&
            layout.imageHeight == capture.height)) {
      return document;
    }
    // Coordinates only make sense relative to the exact captured pixel size.
    return ScreenshotTranslationOcrDocument(text: document.text);
  }
}

final class ScreenshotTranslationCaptureException implements Exception {
  const ScreenshotTranslationCaptureException(
    this.message, {
    this.code = 'capture_failed',
  });

  final String message;
  final String code;

  @override
  String toString() => message;
}
