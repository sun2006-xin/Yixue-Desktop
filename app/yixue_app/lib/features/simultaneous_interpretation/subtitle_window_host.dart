import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'subtitle_window_view.dart';

const subtitleWindowChildArgument = '--yixue-subtitle-child';
const subtitleWindowPortPrefix = '--yixue-subtitle-port=';
const subtitleWindowTokenPrefix = '--yixue-subtitle-token=';
const _subtitleSocketWriteTimeout = Duration(seconds: 2);
const _subtitleSocketCloseTimeout = Duration(seconds: 1);
const _subtitleProcessExitTimeout = Duration(seconds: 2);

/// Display-only controls shared by the live workbench and lifecycle tests.
abstract interface class SubtitleWindowController {
  bool get isVisible;

  Future<void> show(SubtitleWindowSnapshot snapshot);

  Future<void> update(SubtitleWindowSnapshot snapshot);

  Future<void> hide();

  Future<void> dispose();
}

/// Coalesces concurrent requests that all need to close the same native child.
///
/// The future is retained even when it fails: a second shutdown path must not
/// call window_manager.close again while the first native close is in flight.
final class SubtitleWindowCloseOnce {
  Future<void>? _closeFuture;

  Future<void> close(Future<void> Function() closeChild) {
    return _closeFuture ??= Future<void>.sync(closeChild);
  }
}

/// Starts and controls the read-only subtitle process owned by the session UI.
///
/// The child receives only short-lived JSON snapshots over a loopback socket.
/// It does not own capture, translation, recordings, or session persistence.
final class SubtitleWindowHost implements SubtitleWindowController {
  SubtitleWindowHost({
    this.onVisibilityChanged,
    this.onFailure,
    this.onControlAction,
  });

  final void Function(bool visible)? onVisibilityChanged;
  final void Function(String message)? onFailure;
  final FutureOr<String> Function(SubtitleWindowControlAction action)?
  onControlAction;

  Future<void> _operations = Future<void>.value();
  Future<void> _controlActions = Future<void>.value();
  Future<void> _socketWrites = Future<void>.value();
  Future<void>? _opening;
  ServerSocket? _server;
  Socket? _socket;
  Process? _process;
  Completer<void>? _pendingVisibility;
  int? _pendingVisibilityRequestId;
  bool? _pendingVisibilityValue;
  int _nextVisibilityRequestId = 0;
  final Set<Process> _expectedProcessExits = <Process>{};
  SubtitleWindowSnapshot? _pendingSnapshot;
  Future<void>? _snapshotPump;
  bool _snapshotFailureReported = false;
  bool _visible = false;
  bool _disposed = false;

  @override
  bool get isVisible => _visible;

  @override
  Future<void> show(SubtitleWindowSnapshot snapshot) => _serialize(() async {
    if (_disposed) throw StateError('The subtitle window host is disposed.');
    await _ensureChild();
    await _send(<String, Object?>{
      'type': 'snapshot',
      'snapshot': snapshot.toJson(),
    });
    await _requestVisibility(true);
    _setVisible(true);
  });

  @override
  Future<void> update(SubtitleWindowSnapshot snapshot) {
    if (_disposed || _socket == null || _process == null) {
      return Future<void>.value();
    }
    // ASR partials can arrive faster than the display process paints. Keep
    // only the newest complete snapshot while one write is in flight.
    _pendingSnapshot = snapshot;
    if (_snapshotPump == null) _startSnapshotPump();
    return Future<void>.value();
  }

  void _startSnapshotPump() {
    final pump = _drainPendingSnapshots();
    _snapshotPump = pump;
    unawaited(
      pump.then(
        (_) {
          if (!identical(_snapshotPump, pump)) return;
          _snapshotPump = null;
          if (_pendingSnapshot != null && !_disposed) _startSnapshotPump();
        },
        onError: (Object error, StackTrace stackTrace) {
          // _drainPendingSnapshots handles transport failures. This is a final
          // guard so a fire-and-forget state update can never become unhandled.
          _pendingSnapshot = null;
          if (identical(_snapshotPump, pump)) _snapshotPump = null;
          _reportFailure('字幕窗更新失败（${_describe(error)}）；同传仍在继续。');
        },
      ),
    );
  }

  Future<void> _drainPendingSnapshots() async {
    while (!_disposed && _pendingSnapshot != null) {
      final socket = _socket;
      final process = _process;
      if (socket == null || process == null) {
        _pendingSnapshot = null;
        return;
      }
      final snapshot = _pendingSnapshot!;
      _pendingSnapshot = null;
      try {
        await _sendTo(socket, <String, Object?>{
          'type': 'snapshot',
          'snapshot': snapshot.toJson(),
        });
        _snapshotFailureReported = false;
      } catch (error) {
        _pendingSnapshot = null;
        if (!_snapshotFailureReported) {
          _snapshotFailureReported = true;
          _reportFailure('字幕窗连接中断（${_describe(error)}）；同传仍在继续。');
        }
        _retireCurrentChildInBackground(
          expectedProcess: process,
          expectedSocket: socket,
          requestClose: false,
        );
        return;
      }
    }
  }

  void _retireCurrentChildInBackground({
    Process? expectedProcess,
    Socket? expectedSocket,
    required bool requestClose,
  }) {
    unawaited(
      _serialize(
        () => _retireCurrentChild(
          expectedProcess: expectedProcess,
          expectedSocket: expectedSocket,
          requestClose: requestClose,
        ),
      ).catchError((Object error) {
        _reportFailure('字幕窗清理失败（${_describe(error)}）。');
      }),
    );
  }

  @override
  Future<void> hide() => _serialize(() async {
    if (_disposed) return;
    if (_socket != null && _process != null) {
      await _requestVisibility(false);
    }
    _setVisible(false);
  });

  @override
  Future<void> dispose() => _serialize(() async {
    if (_disposed) return;
    _disposed = true;
    await _retireCurrentChild(requestClose: true);
  });

  Future<void> _serialize(Future<void> Function() operation) {
    final next = _operations.then((_) => operation());
    _operations = next.catchError((Object _) {});
    return next;
  }

  Future<void> _ensureChild() {
    if (_process != null && _socket != null) return Future<void>.value();
    final opening = _opening;
    if (opening != null) return opening;

    late final Future<void> operation;
    operation = _startChild().whenComplete(() {
      if (identical(_opening, operation)) _opening = null;
    });
    _opening = operation;
    return operation;
  }

  Future<void> _startChild() async {
    // Reap a disconnected child before replacing its process reference. This
    // prevents repeated reconnects from leaving subtitle windows in the
    // background.
    await _retireCurrentChild(requestClose: true);
    if (_process != null) {
      throw StateError('旧字幕窗进程尚未确认退出，暂不启动新窗口。');
    }
    final server = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
      shared: false,
    );
    _server = server;
    Process? process;
    Socket? socket;
    final token = _newToken();
    try {
      final executable = Platform.resolvedExecutable;
      process = await Process.start(executable, <String>[
        subtitleWindowChildArgument,
        '$subtitleWindowPortPrefix${server.port}',
        '$subtitleWindowTokenPrefix$token',
      ], workingDirectory: File(executable).parent.path);
      _process = process;
      unawaited(process.stdout.drain<void>().catchError((Object _) {}));
      unawaited(process.stderr.drain<void>().catchError((Object _) {}));
      unawaited(
        process.exitCode.then(
          (exitCode) => _handleChildExit(process!, exitCode),
        ),
      );

      socket = await Future.any<Socket>(<Future<Socket>>[
        server.first.timeout(const Duration(seconds: 15)),
        process.exitCode.then<Socket>(
          (exitCode) => throw StateError('字幕窗口在连接前退出（代码 $exitCode）。'),
        ),
      ]);
      final messages = StreamIterator<String>(
        socket
            .cast<List<int>>()
            .transform(utf8.decoder)
            .transform(const LineSplitter()),
      );
      if (!await messages.moveNext().timeout(const Duration(seconds: 5))) {
        throw StateError('字幕窗口未完成本机连接握手。');
      }
      final hello = jsonDecode(messages.current);
      if (hello is! Map ||
          hello['type'] != 'ready' ||
          hello['token'] != token) {
        throw StateError('字幕窗口本机连接验证失败。');
      }

      _socket = socket;
      unawaited(_monitorChildMessages(messages, socket, process));
    } catch (error) {
      _failPendingVisibility(StateError('字幕窗口启动失败：${_describe(error)}'));
      if (identical(_socket, socket)) _socket = null;
      if (socket != null) await _closeSocket(socket, requestClose: false);
      if (process != null) {
        final stopped = await _stopProcess(process, requestClose: false);
        if (stopped && identical(_process, process)) _process = null;
      }
      rethrow;
    } finally {
      await server.close();
      if (identical(_server, server)) _server = null;
    }
  }

  Future<void> _monitorChildMessages(
    StreamIterator<String> messages,
    Socket socket,
    Process process,
  ) async {
    try {
      while (await messages.moveNext()) {
        _handleChildMessage(messages.current, socket);
      }
    } catch (error) {
      _failPendingVisibility(StateError('字幕窗连接中断：${_describe(error)}'));
    } finally {
      try {
        await messages.cancel();
      } catch (_) {
        // The socket may have been closed while the process was exiting.
      }
      if (identical(_socket, socket) && identical(_process, process)) {
        _retireCurrentChildInBackground(
          expectedProcess: process,
          expectedSocket: socket,
          requestClose: false,
        );
      }
    }
  }

  void _handleChildExit(Process process, int exitCode) {
    final expectedExit = _expectedProcessExits.remove(process);
    if (!identical(_process, process)) return;
    _process = null;
    final socket = _socket;
    _socket = null;
    socket?.destroy();
    _failPendingVisibility(StateError('字幕窗口进程已退出（代码 $exitCode）。'));
    final wasVisible = _visible;
    _setVisible(false);
    if (!expectedExit && !_disposed && wasVisible && exitCode != 0) {
      _reportFailure('字幕窗意外退出（代码 $exitCode）；同传仍在继续。');
    }
  }

  Future<void> _send(Map<String, Object?> message) async {
    final socket = _socket;
    if (socket == null) {
      throw StateError('字幕窗口连接已关闭。');
    }
    await _sendTo(socket, message);
  }

  Future<void> _sendTo(Socket socket, Map<String, Object?> message) async {
    final operation = _socketWrites.then((_) async {
      socket.writeln(jsonEncode(message));
      await socket.flush().timeout(_subtitleSocketWriteTimeout);
    });
    _socketWrites = operation.catchError((Object _) {});
    await operation;
  }

  Future<void> _requestVisibility(bool visible) async {
    final completer = Completer<void>();
    final requestId = ++_nextVisibilityRequestId;
    _pendingVisibility = completer;
    _pendingVisibilityRequestId = requestId;
    _pendingVisibilityValue = visible;
    final response = completer.future.timeout(const Duration(seconds: 5));
    try {
      await Future.wait<void>(<Future<void>>[
        _send(<String, Object?>{
          'type': 'visibility',
          'requestId': requestId,
          'visible': visible,
        }),
        response,
      ]);
    } catch (_) {
      final process = _process;
      final socket = _socket;
      _retireCurrentChildInBackground(
        expectedProcess: process,
        expectedSocket: socket,
        requestClose: true,
      );
      rethrow;
    } finally {
      if (identical(_pendingVisibility, completer)) {
        _pendingVisibility = null;
        _pendingVisibilityRequestId = null;
        _pendingVisibilityValue = null;
      }
    }
  }

  void _handleChildMessage(String line, Socket socket) {
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      _failPendingVisibility(StateError('字幕窗返回了无效响应。'));
      return;
    }
    if (decoded is! Map) return;
    if (decoded['type'] == 'control_action') {
      final requestId = decoded['requestId'];
      final actionName = decoded['action'];
      SubtitleWindowControlAction? action;
      if (actionName is String) {
        for (final candidate in SubtitleWindowControlAction.values) {
          if (candidate.name == actionName) {
            action = candidate;
            break;
          }
        }
      }
      if (requestId is int && action != null) {
        _queueControlAction(socket, requestId, action);
      }
      return;
    }
    final completer = _pendingVisibility;
    if (completer == null ||
        decoded['requestId'] != _pendingVisibilityRequestId) {
      return;
    }

    if (decoded['type'] == 'visibility_ack' &&
        decoded['visible'] == _pendingVisibilityValue) {
      _pendingVisibility = null;
      _pendingVisibilityRequestId = null;
      _pendingVisibilityValue = null;
      if (!completer.isCompleted) completer.complete();
      return;
    }
    if (decoded['type'] == 'error') {
      final code = decoded['code'] is String ? decoded['code'] as String : null;
      final message = decoded['message'] is String
          ? decoded['message'] as String
          : '字幕窗口操作失败。';
      _pendingVisibility = null;
      _pendingVisibilityRequestId = null;
      _pendingVisibilityValue = null;
      if (!completer.isCompleted) {
        completer.completeError(
          StateError(code == null ? message : '$code：$message'),
        );
      }
    }
  }

  void _queueControlAction(
    Socket socket,
    int requestId,
    SubtitleWindowControlAction action,
  ) {
    final operation = _controlActions.then((_) async {
      String message;
      try {
        final handler = onControlAction;
        if (handler == null) {
          throw StateError('当前主窗口不支持字幕窗控制。');
        }
        message = await handler(action);
      } catch (error) {
        message = '操作未完成：${_describe(error)}';
      }
      try {
        if (identical(_socket, socket)) {
          await _sendTo(socket, <String, Object?>{
            'type': 'control_result',
            'requestId': requestId,
            'message': message,
          });
        }
      } catch (error) {
        _reportFailure('字幕窗设置结果未能送达（${_describe(error)}）。');
      }
    });
    _controlActions = operation.catchError((Object _) {});
  }

  void _failPendingVisibility(Object error) {
    final completer = _pendingVisibility;
    _pendingVisibility = null;
    _pendingVisibilityRequestId = null;
    _pendingVisibilityValue = null;
    if (completer != null && !completer.isCompleted) {
      completer.completeError(error);
    }
  }

  Future<void> _retireCurrentChild({
    Process? expectedProcess,
    Socket? expectedSocket,
    bool requestClose = true,
  }) async {
    if (expectedProcess != null && !identical(_process, expectedProcess)) {
      return;
    }
    final currentSocket = _socket;
    if (expectedSocket != null &&
        currentSocket != null &&
        !identical(currentSocket, expectedSocket)) {
      return;
    }
    final process = _process;
    final socket = currentSocket;
    final server = _server;
    _socket = null;
    _server = null;
    _failPendingVisibility(StateError('字幕窗连接已关闭。'));
    _pendingSnapshot = null;
    _setVisible(false);
    if (server != null) {
      try {
        await server.close();
      } catch (_) {
        // The server may already be closed during startup cleanup.
      }
    }
    if (process != null) {
      final stopped = await _stopProcess(
        process,
        socket: socket,
        requestClose: requestClose,
      );
      if (stopped && identical(_process, process)) _process = null;
    } else if (socket != null) {
      await _closeSocket(socket, requestClose: requestClose);
    }
  }

  Future<bool> _stopProcess(
    Process process, {
    Socket? socket,
    required bool requestClose,
  }) async {
    _expectedProcessExits.add(process);
    if (socket != null) await _closeSocket(socket, requestClose: requestClose);
    try {
      await process.exitCode.timeout(_subtitleProcessExitTimeout);
      return true;
    } on TimeoutException {
      // This is the host-owned, read-only subtitle UI process. Close it only
      // after the graceful IPC close has failed to stop it in time.
      final killed = process.kill();
      try {
        await process.exitCode.timeout(_subtitleProcessExitTimeout);
        return true;
      } on TimeoutException {
        _reportFailure(
          killed
              ? '字幕窗子进程已请求强制退出，但仍未确认退出；暂不启动第二个字幕窗。'
              : '字幕窗子进程拒绝退出；暂不启动第二个字幕窗。',
        );
        return false;
      }
    } finally {
      _expectedProcessExits.remove(process);
    }
  }

  Future<void> _closeSocket(Socket socket, {required bool requestClose}) async {
    if (requestClose) {
      try {
        socket.writeln(jsonEncode(<String, Object?>{'type': 'close'}));
        await socket.flush().timeout(_subtitleSocketWriteTimeout);
      } catch (_) {
        // The child may already be closing or the connection may be broken.
      }
    }
    try {
      await socket.close().timeout(_subtitleSocketCloseTimeout);
    } on Object {
      socket.destroy();
    }
  }

  void _reportFailure(String message) {
    if (_disposed) return;
    try {
      onFailure?.call(message);
    } catch (_) {
      // Display-only callbacks must never escape into process lifecycle work.
    }
  }

  String _describe(Object error) {
    if (error is TimeoutException) return '等待字幕窗响应超时';
    if (error is ProcessException) return '子进程启动失败';
    final text = error.toString().trim();
    return text.isEmpty ? '未知错误' : text;
  }

  void _setVisible(bool value) {
    if (_visible == value) return;
    _visible = value;
    try {
      onVisibilityChanged?.call(value);
    } catch (_) {
      // Keep native child state transitions isolated from UI listener errors.
    }
  }

  String _newToken() {
    final random = Random.secure();
    return base64UrlEncode(
      List<int>.generate(32, (_) => random.nextInt(256), growable: false),
    ).replaceAll('=', '');
  }
}
