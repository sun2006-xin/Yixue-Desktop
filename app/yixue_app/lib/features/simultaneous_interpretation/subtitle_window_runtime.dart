import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';
import 'package:yixue_app/app/app_theme.dart';

import 'subtitle_window_host.dart';
import 'subtitle_display_preferences.dart';
import 'subtitle_window_view.dart';

const MethodChannel _nativeSubtitleWindowChannel = MethodChannel(
  'com.yixue.yixue_app/subtitle_window/native',
);
const _subtitleWindowSocketWriteTimeout = Duration(seconds: 2);

bool hasSubtitleWindowChildArgument(List<String> arguments) =>
    arguments.contains(subtitleWindowChildArgument);

/// Starts a dedicated subtitle process when the native runner passes its
/// private child-process arguments. Returns false for the main application.
Future<bool> runSubtitleWindowIfRequested(List<String> arguments) async {
  if (!Platform.isWindows) return false;
  final childArguments = SubtitleWindowChildArguments.parse(arguments);
  if (childArguments == null) return false;

  final socket = await _connectToSubtitleOwner(childArguments);
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(
      size: Size(1000, 180),
      minimumSize: Size(720, 132),
      maximumSize: Size(1600, 320),
      title: '译学实时字幕',
      titleBarStyle: TitleBarStyle.hidden,
      windowButtonVisibility: false,
      alwaysOnTop: true,
    ),
  );
  try {
    await windowManager.setAlwaysOnTop(true);
  } catch (error) {
    stderr.writeln('Could not make subtitle window always on top: $error');
  }
  try {
    await windowManager.setOpacity(
      SubtitleDisplayPreferences.defaults.windowOpacity,
    );
  } catch (error) {
    stderr.writeln('Subtitle window opacity is unavailable: $error');
  }

  final snapshot = ValueNotifier<SubtitleWindowSnapshot?>(null);
  final controlMessage = ValueNotifier<String?>(null);
  final closeOnce = SubtitleWindowCloseOnce();
  var queuedMessages = Future<void>.value();
  var ownerDisconnected = false;
  Timer? ownerDisconnectWatchdog;
  var nextControlRequestId = 0;
  var latestControlRequestId = 0;

  Future<void> requestControlAction(SubtitleWindowControlAction action) async {
    final requestId = ++nextControlRequestId;
    latestControlRequestId = requestId;
    controlMessage.value = '正在应用设置…';
    try {
      socket.writeln(
        jsonEncode(<String, Object?>{
          'type': 'control_action',
          'requestId': requestId,
          'action': action.name,
        }),
      );
      await socket.flush().timeout(_subtitleWindowSocketWriteTimeout);
    } on Object {
      controlMessage.value = '无法连接同传主窗口，请返回主窗口重试。';
    }
  }

  Future<void> requestWindowClose() => closeOnce.close(() async {
    try {
      await windowManager.close();
    } catch (_) {
      // This executable branch owns only a read-only display window. If the
      // native close request fails, exiting cannot lose session data.
      exit(0);
    }
    // If the owner disappears before it can reap this child, keep the child
    // from lingering when the plugin reports close completion but Win32 does
    // not finish tearing down the window.
    unawaited(
      Future<void>.delayed(const Duration(seconds: 3), () {
        exit(0);
      }),
    );
  });

  void closeAfterOwnerDisconnect() {
    if (ownerDisconnected) return;
    ownerDisconnected = true;
    // Disconnect can happen while a visibility message is still awaiting a
    // native window call. Queue teardown behind that message to avoid racing
    // close with show/hide, but never leave a detached display process alive.
    ownerDisconnectWatchdog = Timer(const Duration(seconds: 5), () => exit(0));
    unawaited(() async {
      try {
        await queuedMessages;
        await requestWindowClose();
      } catch (error) {
        stderr.writeln('Subtitle window close failed: $error');
        exit(0);
      } finally {
        ownerDisconnectWatchdog?.cancel();
        ownerDisconnectWatchdog = null;
      }
    }());
  }

  Future<void> sendResponse(Map<String, Object?> response) async {
    try {
      socket.writeln(jsonEncode(response));
      await socket.flush().timeout(_subtitleWindowSocketWriteTimeout);
    } on Object {
      // The owner may have exited while this child was replying.
      socket.destroy();
    }
  }

  Future<void> handleLine(String line) async {
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      return;
    }
    if (decoded is! Map) return;
    final type = decoded['type'];
    if (type == 'snapshot') {
      final value = decoded['snapshot'];
      if (value is Map) {
        try {
          snapshot.value = SubtitleWindowSnapshot.fromJson(
            Map<String, dynamic>.from(value),
          );
          try {
            await windowManager.setOpacity(
              snapshot.value!.displayPreferences.windowOpacity,
            );
          } catch (error) {
            stderr.writeln('Could not update subtitle window opacity: $error');
          }
        } on FormatException {
          // Ignore malformed or unsupported transient snapshots.
        } on TypeError {
          // Ignore payloads with values from an unknown schema.
        }
      }
      return;
    }
    if (type == 'control_result') {
      if (decoded['requestId'] != latestControlRequestId) return;
      final message = decoded['message'];
      controlMessage.value = message is String ? message : '设置已更新。';
      return;
    }
    if (type == 'visibility') {
      final requestId = decoded['requestId'];
      final visible = decoded['visible'] == true;
      try {
        if (visible) {
          if (snapshot.value == null) {
            throw StateError('还没有可显示的字幕内容。');
          }
          // Let Flutter paint the latest snapshot before showing the native
          // window, then acknowledge only after Win32 confirms the operation.
          await WidgetsBinding.instance.endOfFrame;
          await _nativeSubtitleWindowChannel.invokeMethod<void>(
            'showNoActivate',
          );
        } else {
          await _nativeSubtitleWindowChannel.invokeMethod<void>('hide');
        }
        await sendResponse(<String, Object?>{
          'type': 'visibility_ack',
          'requestId': requestId,
          'visible': visible,
        });
      } catch (error) {
        final code = error is PlatformException ? error.code : 'window_error';
        final message = error is PlatformException
            ? (error.message ?? error.code)
            : error.toString();
        await sendResponse(<String, Object?>{
          'type': 'error',
          'requestId': requestId,
          'code': code,
          'message': message,
        });
      }
      return;
    }
    if (type == 'close') {
      await requestWindowClose();
    }
  }

  socket
      .cast<List<int>>()
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen(
        (message) {
          queuedMessages = queuedMessages
              .then((_) => handleLine(message))
              .catchError((Object error) {
                stderr.writeln('Subtitle window IPC failed: $error');
              });
        },
        onDone: closeAfterOwnerDisconnect,
        onError: (Object _) => closeAfterOwnerDisconnect(),
        cancelOnError: true,
      );

  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.vitality(),
      home: ValueListenableBuilder<SubtitleWindowSnapshot?>(
        valueListenable: snapshot,
        builder: (context, value, _) => value == null
            ? const Scaffold(body: SizedBox.shrink())
            : ValueListenableBuilder<String?>(
                valueListenable: controlMessage,
                builder: (context, message, _) => SubtitleWindowView(
                  snapshot: value,
                  controlMessage: message,
                  onControlAction: (action) =>
                      unawaited(requestControlAction(action)),
                  onClose: () => unawaited(requestWindowClose()),
                ),
              ),
      ),
    ),
  );
  await WidgetsBinding.instance.endOfFrame;
  socket.writeln(
    jsonEncode(<String, Object?>{
      'type': 'ready',
      'token': childArguments.token,
    }),
  );
  await socket.flush().timeout(_subtitleWindowSocketWriteTimeout);
  return true;
}

final class SubtitleWindowChildArguments {
  const SubtitleWindowChildArguments({required this.port, required this.token});

  final int port;
  final String token;

  static SubtitleWindowChildArguments? parse(List<String> arguments) {
    if (!arguments.contains(subtitleWindowChildArgument)) return null;
    int? port;
    String? token;
    for (final argument in arguments) {
      if (argument.startsWith(subtitleWindowPortPrefix)) {
        port = int.tryParse(
          argument.substring(subtitleWindowPortPrefix.length),
        );
      } else if (argument.startsWith(subtitleWindowTokenPrefix)) {
        token = argument.substring(subtitleWindowTokenPrefix.length);
      }
    }
    if (port == null ||
        port < 1 ||
        port > 65535 ||
        token == null ||
        token.isEmpty) {
      throw const FormatException('Invalid subtitle child process arguments.');
    }
    return SubtitleWindowChildArguments(port: port, token: token);
  }
}

Future<Socket> _connectToSubtitleOwner(
  SubtitleWindowChildArguments arguments,
) async {
  Object? lastError;
  for (var attempt = 0; attempt < 20; attempt += 1) {
    try {
      return await Socket.connect(
        InternetAddress.loopbackIPv4,
        arguments.port,
        timeout: const Duration(milliseconds: 500),
      );
    } catch (error) {
      lastError = error;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
  throw StateError('无法连接译学字幕主窗口：$lastError');
}
