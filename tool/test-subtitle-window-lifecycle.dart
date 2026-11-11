import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';

const _childArgument = '--yixue-subtitle-child';
const _portPrefix = '--yixue-subtitle-port=';
const _tokenPrefix = '--yixue-subtitle-token=';
typedef _GetForegroundWindowNative = IntPtr Function();
typedef _GetForegroundWindowDart = int Function();
final _getForegroundWindow = DynamicLibrary.open('user32.dll')
    .lookupFunction<_GetForegroundWindowNative, _GetForegroundWindowDart>(
      'GetForegroundWindow',
    );

Future<void> main(List<String> arguments) async {
  if (!Platform.isWindows) {
    stderr.writeln('This lifecycle smoke test runs on Windows only.');
    exitCode = 2;
    return;
  }
  if (arguments.length != 1) {
    stderr.writeln('Usage: dart test-subtitle-window-lifecycle.dart <exe>');
    exitCode = 2;
    return;
  }

  final executable = File(arguments.single).absolute;
  if (!await executable.exists()) {
    stderr.writeln('Subtitle-window executable not found: ${executable.path}');
    exitCode = 2;
    return;
  }

  await _runLifecycle(executable, disconnectOwner: false);
  await _runLifecycle(executable, disconnectOwner: true);
  stdout.writeln(
    'PASS: subtitle child opened, hid, reopened, closed, and exits after owner disconnect; no capture was started.',
  );
}

Future<void> _runLifecycle(
  File executable, {
  required bool disconnectOwner,
}) async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final token = _newToken();
  Process? child;
  Socket? socket;
  StreamIterator<String>? messages;
  try {
    child = await Process.start(executable.path, <String>[
      _childArgument,
      '$_portPrefix${server.port}',
      '$_tokenPrefix$token',
    ], workingDirectory: executable.parent.path);
    unawaited(child.stdout.drain<void>());
    unawaited(child.stderr.drain<void>());
    socket = await server.first.timeout(const Duration(seconds: 15));
    messages = StreamIterator<String>(
      socket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter()),
    );

    final ready = jsonDecode(await _nextLine(messages)) as Map<String, dynamic>;
    _expect(
      ready['type'] == 'ready' && ready['token'] == token,
      'child startup handshake was invalid',
    );
    final foregroundBeforeShow = _getForegroundWindow();
    socket.writeln(
      jsonEncode(<String, Object?>{
        'type': 'snapshot',
        'snapshot': <String, Object?>{
          'schemaVersion': 1,
          'sessionId': 'lifecycle-smoke',
          'sessionKind': 'meeting',
          'sessionStatus': 'capturing',
          'sourceKind': 'systemOutput',
          'sourceLabel': 'Smoke test (no capture)',
          'sourceStatusLabel': '模拟字幕，仅验证窗口生命周期',
          'sourceLanguageLabel': 'English',
          'targetLanguageLabel': '中文',
          'translationStatusLabel': '生命周期测试',
          'displayPreferences': <String, Object?>{
            'schemaVersion': 1,
            'mode': 'bilingual',
            'fontScale': 'standard',
            'highContrast': true,
          },
          'cues': <Map<String, Object?>>[
            <String, Object?>{
              'cueId': 'smoke-1',
              'sourceText': 'Subtitle window lifecycle check.',
              'translatedText': '字幕窗口生命周期检查。',
              'languageCode': 'en',
              'sourceIsFinal': true,
              'translationStatusLabel': null,
            },
          ],
        },
      }),
    );
    await socket.flush();

    var requestId = 0;
    await _setVisibility(
      socket,
      messages,
      visible: true,
      requestId: ++requestId,
    );
    await Future<void>.delayed(const Duration(milliseconds: 150));
    final foregroundAfterFirstShow = _getForegroundWindow();
    stdout.writeln(
      'foreground before=${foregroundBeforeShow.toRadixString(16)} first=${foregroundAfterFirstShow.toRadixString(16)}',
    );
    _expect(
      foregroundBeforeShow == 0 ||
          foregroundAfterFirstShow == foregroundBeforeShow,
      'showing the subtitle window changed the foreground window',
    );
    await _setVisibility(
      socket,
      messages,
      visible: false,
      requestId: ++requestId,
    );
    final foregroundBeforeReopen = _getForegroundWindow();
    await _setVisibility(
      socket,
      messages,
      visible: true,
      requestId: ++requestId,
    );
    await Future<void>.delayed(const Duration(milliseconds: 150));
    final foregroundAfterReopen = _getForegroundWindow();
    stdout.writeln(
      'foreground before reopen=${foregroundBeforeReopen.toRadixString(16)} after reopen=${foregroundAfterReopen.toRadixString(16)}',
    );
    _expect(
      foregroundBeforeReopen == 0 ||
          foregroundAfterReopen == foregroundBeforeReopen,
      'reopening the subtitle window changed the foreground window',
    );

    if (disconnectOwner) {
      await socket.close();
    } else {
      socket.writeln(jsonEncode(<String, Object?>{'type': 'close'}));
      await socket.flush();
      await socket.close();
    }

    final exit = await child.exitCode.timeout(const Duration(seconds: 8));
    _expect(exit == 0, 'child exited with code $exit');
  } finally {
    if (messages != null) {
      try {
        await messages.cancel();
      } on Object {
        // The child or the smoke-test socket may already have closed.
      }
    }
    socket?.destroy();
    await server.close();
    if (child != null) {
      final exit = await child.exitCode.timeout(
        const Duration(seconds: 3),
        onTimeout: () {
          child!.kill();
          return -1;
        },
      );
      if (exit == -1) {
        stderr.writeln('Cleanup had to terminate test child ${child.pid}.');
      }
    }
  }
}

Future<void> _setVisibility(
  Socket socket,
  StreamIterator<String> messages, {
  required bool visible,
  required int requestId,
}) async {
  socket.writeln(
    jsonEncode(<String, Object?>{
      'type': 'visibility',
      'requestId': requestId,
      'visible': visible,
    }),
  );
  await socket.flush();
  final response =
      jsonDecode(await _nextLine(messages)) as Map<String, dynamic>;
  _expect(
    response['type'] == 'visibility_ack' &&
        response['requestId'] == requestId &&
        response['visible'] == visible,
    'visibility request $requestId was not acknowledged: $response',
  );
}

Future<String> _nextLine(StreamIterator<String> messages) async {
  if (!await messages.moveNext().timeout(const Duration(seconds: 8))) {
    throw StateError('subtitle child closed before replying');
  }
  return messages.current;
}

String _newToken() {
  final random = Random.secure();
  return base64UrlEncode(
    List<int>.generate(32, (_) => random.nextInt(256), growable: false),
  ).replaceAll('=', '');
}

void _expect(bool condition, String message) {
  if (!condition) throw StateError(message);
}
