import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart' hide Image;
import 'package:flutter/services.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'app_exit_cleanup_registry.dart';

enum _CloseChoice { hideToTray, quit, cancel }

enum _SystemShutdownCleanupWaitState {
  completed,
  attemptTimedOut,
  deadlineReached,
  failed,
}

final class _SystemShutdownCleanupWait {
  const _SystemShutdownCleanupWait.completed()
    : state = _SystemShutdownCleanupWaitState.completed,
      error = null,
      stackTrace = null;

  const _SystemShutdownCleanupWait.attemptTimedOut()
    : state = _SystemShutdownCleanupWaitState.attemptTimedOut,
      error = null,
      stackTrace = null;

  const _SystemShutdownCleanupWait.deadlineReached()
    : state = _SystemShutdownCleanupWaitState.deadlineReached,
      error = null,
      stackTrace = null;

  const _SystemShutdownCleanupWait.failed(this.error, this.stackTrace)
    : state = _SystemShutdownCleanupWaitState.failed;

  final _SystemShutdownCleanupWaitState state;
  final Object? error;
  final StackTrace? stackTrace;
}

enum WindowsClosePreference { hideToTray, quit }

const _nativeSupervisorChannel = MethodChannel(
  'com.yixue.yixue_app/supervisor',
);
const _nativeWindowActivationChannel = MethodChannel(
  'com.yixue.yixue_app/window_activation',
);

typedef WindowsUiCleanupWatchdogSignal = Future<void> Function();

Future<void> signalWindowsUiCleanupWatchdogStart() =>
    _nativeSupervisorChannel.invokeMethod<void>('signalUiCleanupWatchdogStart');

@visibleForTesting
Future<bool> restoreWindowsWindowAfterTrayFailure({
  required Future<void> Function() restoreTaskbar,
  required Future<void> Function() showWindow,
  required Future<void> Function() disposeTrayIcon,
  Duration timeout = const Duration(milliseconds: 200),
}) async {
  var taskbarRestored = false;
  var windowShown = false;
  try {
    await restoreTaskbar().timeout(timeout);
    taskbarRestored = true;
  } on Object {
    // Keep the visible tray icon as a recovery entry if the taskbar state is
    // unknown or the native window host has stopped responding.
  }
  try {
    await showWindow().timeout(timeout);
    windowShown = true;
  } on Object {
    // The tray icon must remain available if the main window cannot be shown.
  }
  if (!taskbarRestored || !windowShown) return false;
  await disposeTrayIcon();
  return true;
}

abstract interface class WindowsAppClosePreferenceStore {
  Future<WindowsClosePreference?> read();

  Future<void> write(WindowsClosePreference preference);
}

final class FileWindowsAppClosePreferenceStore
    implements WindowsAppClosePreferenceStore {
  FileWindowsAppClosePreferenceStore(this.file);

  final File file;

  @override
  Future<WindowsClosePreference?> read() async {
    try {
      if (!await file.exists()) return null;
      final value = jsonDecode(await file.readAsString());
      if (value is! Map || value['schemaVersion'] != 1) return null;
      return switch (value['preference']) {
        'hideToTray' => WindowsClosePreference.hideToTray,
        'quit' => WindowsClosePreference.quit,
        _ => null,
      };
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> write(WindowsClosePreference preference) async {
    await file.parent.create(recursive: true);
    await file.writeAsString(
      jsonEncode(<String, Object>{
        'schemaVersion': 1,
        'preference': preference.name,
      }),
      flush: true,
    );
  }
}

/// Owns the explicit Windows close, hide-to-tray, and quit flows.
///
/// The tray is created only after the user chooses to hide the app. Startup
/// error and data-directory setup screens do not use this controller, so their
/// close buttons remain available for recovery.
final class WindowsAppCloseController extends WindowListener {
  WindowsAppCloseController({
    required GlobalKey<NavigatorState> navigatorKey,
    Duration exitCleanupTimeout = const Duration(seconds: 20),
    Duration systemShutdownCleanupTimeout = const Duration(seconds: 20),
    Duration systemShutdownFastCleanupTimeout = const Duration(seconds: 2),
    Duration systemShutdownCleanupTotalTimeout = const Duration(seconds: 40),
    Duration systemShutdownCleanupRetryDelay = const Duration(seconds: 5),
    Duration closePreferenceReadTimeout = const Duration(milliseconds: 500),
    Duration closePreferenceWriteTimeout = const Duration(milliseconds: 500),
    WindowsAppClosePreferenceStore? preferenceStore,
    void Function()? processExit,
    WindowsUiCleanupWatchdogSignal? nativeCleanupWatchdogSignal,
  }) : _navigatorKey = navigatorKey,
       _exitCleanupTimeout = exitCleanupTimeout,
       _systemShutdownCleanupTimeout = systemShutdownCleanupTimeout,
       _systemShutdownFastCleanupTimeout = systemShutdownFastCleanupTimeout,
       // The public testable option remains separate from its private state.
       // ignore: prefer_initializing_formals
       _systemShutdownCleanupTotalTimeout = systemShutdownCleanupTotalTimeout,
       _systemShutdownCleanupRetryDelay = systemShutdownCleanupRetryDelay,
       _closePreferenceReadTimeout = closePreferenceReadTimeout,
       _closePreferenceWriteTimeout = closePreferenceWriteTimeout,
       _preferenceStore = preferenceStore,
       _processExit = processExit,
       _nativeCleanupWatchdogSignal = nativeCleanupWatchdogSignal;

  static const _trayAsset = 'assets/brand/yixue-logo-master-v3.png';
  static const _windowOperationTimeout = Duration(milliseconds: 500);
  static const _windowRollbackTimeout = Duration(milliseconds: 200);
  static const _systemShutdownCleanupRetryLimit = 3;

  final GlobalKey<NavigatorState> _navigatorKey;
  final Duration _exitCleanupTimeout;
  final Duration _systemShutdownCleanupTimeout;
  final Duration _systemShutdownFastCleanupTimeout;
  final Duration _systemShutdownCleanupTotalTimeout;
  final Duration _systemShutdownCleanupRetryDelay;
  final Duration _closePreferenceReadTimeout;
  final Duration _closePreferenceWriteTimeout;
  final WindowsAppClosePreferenceStore? _preferenceStore;
  final void Function()? _processExit;
  final WindowsUiCleanupWatchdogSignal? _nativeCleanupWatchdogSignal;

  TrayIcon? _trayIcon;
  Image? _trayImage;
  Menu? _trayMenu;
  MenuItem? _showWindowItem;
  MenuItem? _quitItem;
  var _attached = false;
  var _handlingCloseRequest = false;
  var _isExiting = false;
  var _closeChoiceDialogShown = false;
  var _systemShutdownRequested = false;
  var _systemShutdownHasExtendedGrace = false;
  var _systemShutdownCleanupDeadlineElapsed = false;
  Timer? _systemShutdownCleanupDeadlineTimer;
  Completer<void>? _systemShutdownCleanupDeadline;
  DialogRoute<_CloseChoice>? _closeChoiceDialogRoute;
  Future<void>? _exitCleanupFuture;

  Future<void> attach() async {
    if (!Platform.isWindows || _attached) return;
    windowManager.addListener(this);
    try {
      _nativeWindowActivationChannel.setMethodCallHandler(
        _handleNativeWindowActivation,
      );
      try {
        await _nativeWindowActivationChannel.invokeMethod<void>('ready');
      } on MissingPluginException {
        // Window-manager tests and direct Flutter hosts may not include the
        // native runner bridge. Normal packaged Windows launches do.
      } on PlatformException catch (error) {
        stderr.writeln('Could not register the Windows restore bridge: $error');
      }
      await windowManager.setPreventClose(true);
      _attached = true;
    } catch (_) {
      windowManager.removeListener(this);
      _nativeWindowActivationChannel.setMethodCallHandler(null);
      rethrow;
    }
  }

  Future<Object?> _handleNativeWindowActivation(MethodCall call) async {
    if (call.method == 'systemShutdown') {
      if (!_systemShutdownRequested) {
        final deadline = Completer<void>();
        _systemShutdownCleanupDeadline = deadline;
        _systemShutdownCleanupDeadlineElapsed = false;
        _systemShutdownCleanupDeadlineTimer = Timer(
          _systemShutdownCleanupTotalTimeout,
          () {
            _systemShutdownCleanupDeadlineElapsed = true;
            deadline.complete();
          },
        );
      }
      _systemShutdownRequested = true;
      _systemShutdownHasExtendedGrace = call.arguments == true;
      final closeChoiceRoute = _closeChoiceDialogRoute;
      if (_closeChoiceDialogShown && closeChoiceRoute != null) {
        final navigator = _navigatorKey.currentState;
        if (navigator != null && closeChoiceRoute.isActive) {
          navigator.removeRoute(closeChoiceRoute, _CloseChoice.quit);
        }
      } else if (!_handlingCloseRequest && !_isExiting) {
        await _requestClose(explicitQuit: true);
      }
      return true;
    }
    if (call.method != 'restoreMainWindow') {
      throw MissingPluginException(
        'Unsupported native window activation: ${call.method}',
      );
    }
    await restoreMainWindow();
    return true;
  }

  @override
  void onWindowClose() {
    if (_isExiting) return;
    unawaited(_requestClose());
  }

  /// Requests the same close flow as the main window's close button.
  Future<void> requestClose() => _requestClose();

  /// Explicitly exits the app, regardless of a remembered hide-to-tray choice.
  Future<void> requestQuit() => _requestClose(explicitQuit: true);

  @visibleForTesting
  Future<void> requestTrayQuitForTesting() => _quitFromTray();

  Future<void> detach() async {
    _systemShutdownCleanupDeadlineTimer?.cancel();
    _systemShutdownCleanupDeadlineTimer = null;
    if (!_attached) return;
    windowManager.removeListener(this);
    _attached = false;
    _nativeWindowActivationChannel.setMethodCallHandler(null);
    await _disposeTrayIcon();
    try {
      await windowManager.setPreventClose(false);
    } catch (_) {
      // The native window may already be gone during Flutter teardown.
    }
  }

  Future<void> _requestClose({bool explicitQuit = false}) async {
    if (_handlingCloseRequest || _isExiting) return;
    _handlingCloseRequest = true;
    try {
      if (explicitQuit || _systemShutdownRequested) {
        await _quitCompletely(showProgress: !_systemShutdownRequested);
        return;
      }
      final context = await _waitForNavigatorContext();
      if (explicitQuit || _systemShutdownRequested) {
        await _quitCompletely(showProgress: !_systemShutdownRequested);
        return;
      }
      if (context == null) {
        // During early startup there may be no Navigator yet. Keep the
        // application alive instead of silently turning a close click into an
        // unprompted exit.
        return;
      }
      final savedPreference = await _readClosePreference();
      if (_systemShutdownRequested) {
        await _quitCompletely(showProgress: false);
        return;
      }
      if (savedPreference == WindowsClosePreference.hideToTray) {
        await _hideToTray();
        if (_systemShutdownRequested) {
          await _quitCompletely(showProgress: false);
        }
        return;
      }
      if (savedPreference == WindowsClosePreference.quit) {
        await _quitCompletely();
        return;
      }

      final dialogContext = _navigatorKey.currentContext;
      if (dialogContext == null || !dialogContext.mounted) return;
      var rememberChoice = false;
      late final _CloseChoice? choice;
      final navigator = _navigatorKey.currentState;
      if (navigator == null) return;
      _closeChoiceDialogShown = true;
      final closeChoiceRoute = DialogRoute<_CloseChoice>(
        context: dialogContext,
        barrierDismissible: false,
        builder: (context) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            scrollable: true,
            insetPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 8,
            ),
            title: const Text('关闭译学'),
            content: SizedBox(
              width: (MediaQuery.sizeOf(context).width - 64)
                  .clamp(0.0, 440.0)
                  .toDouble(),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    key: ValueKey('close-dialog-description'),
                    '请选择关闭方式。隐藏到系统托盘后，译学和正在运行的同传会继续工作；彻底退出会先停止采集并保存字幕。',
                  ),
                  if (_preferenceStore != null) ...[
                    const SizedBox(height: 8),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      value: rememberChoice,
                      title: const Text('记住选择，下次不再询问'),
                      onChanged: (value) =>
                          setDialogState(() => rememberChoice = value == true),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(_CloseChoice.cancel),
                child: const Text('取消'),
              ),
              OutlinedButton(
                onPressed: () =>
                    Navigator.of(context).pop(_CloseChoice.hideToTray),
                child: const Text('隐藏到系统托盘'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(_CloseChoice.quit),
                child: const Text('彻底退出'),
              ),
            ],
          ),
        ),
      );
      _closeChoiceDialogRoute = closeChoiceRoute;
      try {
        choice = await navigator.push<_CloseChoice>(closeChoiceRoute);
      } finally {
        _closeChoiceDialogRoute = null;
        _closeChoiceDialogShown = false;
      }

      if (_systemShutdownRequested) {
        await _quitCompletely(showProgress: false);
        return;
      }
      if (rememberChoice && choice != null && choice != _CloseChoice.cancel) {
        await _writeClosePreference(
          choice == _CloseChoice.quit
              ? WindowsClosePreference.quit
              : WindowsClosePreference.hideToTray,
        );
      }
      if (_systemShutdownRequested) {
        await _quitCompletely(showProgress: false);
        return;
      }
      switch (choice) {
        case _CloseChoice.hideToTray:
          await _hideToTray();
          if (_systemShutdownRequested) {
            await _quitCompletely(showProgress: false);
          }
          break;
        case _CloseChoice.quit:
          await _quitCompletely();
          break;
        case _CloseChoice.cancel:
        case null:
          break;
      }
    } catch (error) {
      if (_systemShutdownRequested) {
        await AppExitCleanupRegistry.recordEvent(
          'system_shutdown_cleanup_error type=${error.runtimeType}',
        );
        try {
          await _quitCompletely(showProgress: false);
        } catch (exitError) {
          stderr.writeln(
            'Could not finish exit during Windows shutdown: $exitError',
          );
        }
      } else {
        await _showOperationError('无法完成关闭操作', error);
      }
    } finally {
      _handlingCloseRequest = false;
    }
  }

  Future<BuildContext?> _waitForNavigatorContext() async {
    for (var attempt = 0; attempt < 40; attempt += 1) {
      if (_systemShutdownRequested) return null;
      final context = _navigatorKey.currentContext;
      if (context != null && context.mounted) return context;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return null;
  }

  Future<WindowsClosePreference?> _readClosePreference() async {
    try {
      return await _preferenceStore?.read().timeout(
        _closePreferenceReadTimeout,
      );
    } catch (error) {
      stderr.writeln('Could not read close preference: $error');
      return null;
    }
  }

  Future<void> _writeClosePreference(WindowsClosePreference preference) async {
    try {
      await _preferenceStore
          ?.write(preference)
          .timeout(_closePreferenceWriteTimeout);
    } catch (error) {
      stderr.writeln('Could not save close preference: $error');
    }
  }

  Future<void> _hideToTray() async {
    try {
      await _ensureTrayIcon();
      final trayIcon = _trayIcon;
      if (trayIcon == null || !trayIcon.setVisible(true)) {
        throw StateError('Windows could not show the system tray icon.');
      }
      await windowManager.setSkipTaskbar(true).timeout(_windowOperationTimeout);
      await windowManager.hide().timeout(_windowOperationTimeout);
    } catch (_) {
      final restored = await restoreWindowsWindowAfterTrayFailure(
        restoreTaskbar: () => windowManager.setSkipTaskbar(false),
        showWindow: windowManager.show,
        disposeTrayIcon: _disposeTrayIcon,
        timeout: _windowRollbackTimeout,
      );
      if (!restored) {
        stderr.writeln(
          'Could not confirm the main window was restored after tray setup failed; keeping the tray icon available for recovery.',
        );
      }
      rethrow;
    }
  }

  Future<void> _ensureTrayIcon() async {
    if (_trayIcon != null) return;
    final trayIcon = TrayIcon.create();
    if (trayIcon == null) {
      throw StateError('Windows did not create the system tray icon.');
    }
    _trayIcon = trayIcon;
    final trayImage = ImageAsset.fromAsset(_trayAsset);
    if (trayImage == null) {
      throw StateError('The bundled system tray icon could not be loaded.');
    }
    _trayImage = trayImage;
    trayIcon.icon = trayImage;
    trayIcon.setContextMenuTrigger(ContextMenuTrigger.rightClicked);
    trayIcon.addListener((event) {
      if (event is TrayIconClickedEvent ||
          event is TrayIconDoubleClickedEvent) {
        _runTrayAction(restoreMainWindow);
      }
    });
    trayIcon.setTooltip('译学助手');

    final menu = Menu.create();
    if (menu == null) {
      throw StateError('Windows did not create the system tray menu.');
    }
    _trayMenu = menu;
    final showItem = MenuItem.createWithLabelAndType(
      '显示译学',
      MenuItemType.normal,
    );
    final quitItem = MenuItem.createWithLabelAndType(
      '彻底退出',
      MenuItemType.normal,
    );
    if (showItem == null || quitItem == null) {
      throw StateError('Windows did not create the system tray menu items.');
    }
    _showWindowItem = showItem;
    _quitItem = quitItem;
    showItem.addListener((event) {
      if (event is MenuItemClickedEvent) {
        _runTrayAction(restoreMainWindow);
      }
    });
    quitItem.addListener((event) {
      if (event is MenuItemClickedEvent) {
        _runTrayAction(_quitFromTray);
      }
    });
    menu.addItem(showItem);
    menu.addSeparator();
    menu.addItem(quitItem);
    trayIcon.setContextMenu(menu);
  }

  /// Restores the same main-window state from the tray or the floating orb.
  Future<void> restoreMainWindow() async {
    if (_isExiting) return;
    await windowManager.setSkipTaskbar(false).timeout(_windowOperationTimeout);
    final isMinimized = await windowManager.isMinimized().timeout(
      _windowOperationTimeout,
    );
    if (isMinimized) {
      await windowManager.restore().timeout(_windowOperationTimeout);
    }
    await windowManager.show().timeout(_windowOperationTimeout);
    await windowManager.focus().timeout(_windowOperationTimeout);
    _trayIcon?.setVisible(false);
  }

  Future<void> _quitFromTray() async {
    if (_handlingCloseRequest || _isExiting) return;
    _handlingCloseRequest = true;
    try {
      if (!_systemShutdownRequested) {
        try {
          await restoreMainWindow();
        } on Object catch (error) {
          if (!_systemShutdownRequested) rethrow;
          stderr.writeln(
            'Could not restore the window during system shutdown: $error',
          );
        }
      }
      await _quitCompletely(showProgress: !_systemShutdownRequested);
    } finally {
      _handlingCloseRequest = false;
    }
  }

  Future<void> _quitCompletely({bool showProgress = true}) async {
    final navigator = _navigatorKey.currentState;
    var systemShutdownCleanupFailures = 0;
    while (true) {
      if (_systemShutdownRequested && _systemShutdownCleanupDeadlineElapsed) {
        await AppExitCleanupRegistry.recordEvent(
          'system_shutdown_cleanup_hard_deadline_exceeded',
        );
        break;
      }
      final initialContext = _navigatorKey.currentContext;
      Completer<void>? progressShown;
      Future<void>? progressDialog;
      if (showProgress &&
          initialContext != null &&
          initialContext.mounted &&
          navigator != null) {
        progressShown = Completer<void>();
        progressDialog = showDialog<void>(
          context: initialContext,
          barrierDismissible: false,
          builder: (context) {
            if (!progressShown!.isCompleted) progressShown.complete();
            return const PopScope(
              canPop: false,
              child: AlertDialog(
                scrollable: true,
                insetPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                key: ValueKey('app-exit-progress'),
                title: Text('正在彻底退出'),
                content: Row(
                  children: [
                    SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    ),
                    SizedBox(width: 16),
                    Expanded(child: Text('正在停止采集、完成录音并保存字幕。请稍候。')),
                  ],
                ),
              ),
            );
          },
        );
        await progressShown.future;
      }

      if (_systemShutdownRequested && _systemShutdownCleanupDeadlineElapsed) {
        if (progressDialog != null && navigator != null && navigator.mounted) {
          if (navigator.canPop()) navigator.pop();
          await progressDialog;
        }
        await AppExitCleanupRegistry.recordEvent(
          'system_shutdown_cleanup_hard_deadline_exceeded '
          'partial_media_may_require_recovery=true',
        );
        break;
      }

      Object? cleanupError;
      StackTrace? cleanupStackTrace;
      Future<void>? cleanupAttempt;
      final cleanupTimeout = _systemShutdownRequested
          ? _systemShutdownHasExtendedGrace
                ? _systemShutdownCleanupTimeout
                : _systemShutdownFastCleanupTimeout
          : _exitCleanupTimeout;
      try {
        await AppExitCleanupRegistry.recordEvent('close_cleanup_begin');
        cleanupAttempt = _prepareExitCleanup();
        if (_systemShutdownRequested) {
          final outcome = await _waitForSystemShutdownCleanup(
            cleanupAttempt,
            attemptTimeout: cleanupTimeout,
          );
          switch (outcome.state) {
            case _SystemShutdownCleanupWaitState.completed:
              await AppExitCleanupRegistry.recordEvent(
                'close_cleanup_end status=ok',
              );
              break;
            case _SystemShutdownCleanupWaitState.attemptTimedOut:
              cleanupError = TimeoutException(
                'Cleanup exceeded ${cleanupTimeout.inSeconds} seconds.',
                cleanupTimeout,
              );
              cleanupStackTrace = StackTrace.current;
              break;
            case _SystemShutdownCleanupWaitState.deadlineReached:
              _systemShutdownCleanupDeadlineElapsed = true;
              break;
            case _SystemShutdownCleanupWaitState.failed:
              cleanupError = outcome.error;
              cleanupStackTrace = outcome.stackTrace;
              break;
          }
        } else {
          await cleanupAttempt.timeout(cleanupTimeout);
          await AppExitCleanupRegistry.recordEvent(
            'close_cleanup_end status=ok',
          );
        }
      } catch (error, stackTrace) {
        await AppExitCleanupRegistry.recordEvent(
          error is TimeoutException
              ? 'close_cleanup_end status=timeout limit_seconds=${cleanupTimeout.inSeconds}'
              : 'close_cleanup_end status=error type=${error.runtimeType}',
        );
        cleanupError = error;
        cleanupStackTrace = stackTrace;
      }

      if (progressDialog != null && navigator != null && navigator.mounted) {
        if (navigator.canPop()) navigator.pop();
        await progressDialog;
      }
      if (_systemShutdownRequested && _systemShutdownCleanupDeadlineElapsed) {
        await AppExitCleanupRegistry.recordEvent(
          'system_shutdown_cleanup_hard_deadline_exceeded '
          'partial_media_may_require_recovery=true',
        );
        break;
      }
      if (cleanupError != null && _systemShutdownRequested) {
        await AppExitCleanupRegistry.recordEvent(
          'system_shutdown_cleanup_incomplete type=${cleanupError.runtimeType}',
        );
        if (cleanupError is TimeoutException && cleanupAttempt != null) {
          // Future.timeout does not cancel the underlying media finalization.
          // Keep awaiting that same attempt, but bound the wait by the total
          // Windows shutdown deadline so a stuck native writer cannot block
          // system shutdown indefinitely or be started a second time.
          final outcome = await _waitForSystemShutdownCleanup(cleanupAttempt);
          switch (outcome.state) {
            case _SystemShutdownCleanupWaitState.completed:
              await AppExitCleanupRegistry.recordEvent(
                'system_shutdown_cleanup_end status=ok_after_timeout',
              );
              cleanupError = null;
              break;
            case _SystemShutdownCleanupWaitState.deadlineReached:
              _systemShutdownCleanupDeadlineElapsed = true;
              break;
            case _SystemShutdownCleanupWaitState.failed:
              cleanupError = outcome.error;
              cleanupStackTrace = outcome.stackTrace;
              break;
            case _SystemShutdownCleanupWaitState.attemptTimedOut:
              // No per-attempt timeout is used while draining the same Future.
              throw StateError('Unexpected system shutdown cleanup timeout.');
          }
        }
        if (_systemShutdownCleanupDeadlineElapsed) {
          await AppExitCleanupRegistry.recordEvent(
            'system_shutdown_cleanup_hard_deadline_exceeded '
            'partial_media_may_require_recovery=true',
          );
          break;
        }
        if (cleanupError != null) {
          systemShutdownCleanupFailures++;
          if (systemShutdownCleanupFailures >=
              _systemShutdownCleanupRetryLimit) {
            await AppExitCleanupRegistry.recordEvent(
              'system_shutdown_cleanup_give_up attempts=$systemShutdownCleanupFailures',
            );
            // Windows shutdown cannot be blocked indefinitely. After three
            // failed cleanup attempts, leave recoverable partial media in
            // place and allow the OS to complete its requested shutdown.
            break;
          }
          if (_systemShutdownCleanupRetryDelay > Duration.zero) {
            await _waitForSystemShutdownRetryDelay();
            if (_systemShutdownCleanupDeadlineElapsed) {
              await AppExitCleanupRegistry.recordEvent(
                'system_shutdown_cleanup_hard_deadline_exceeded '
                'partial_media_may_require_recovery=true',
              );
              break;
            }
          }
          continue;
        }
      }
      if (cleanupError == null) break;

      await restoreMainWindow();
      final context = _navigatorKey.currentContext;
      if (context == null || !context.mounted) {
        Error.throwWithStackTrace(cleanupError, cleanupStackTrace!);
      }
      final timedOut = cleanupError is TimeoutException;
      final content = timedOut
          ? '同传收尾已等待 ${cleanupTimeout.inSeconds} 秒，仍有操作没有结束。可以返回译学，或继续等待保存完成。请勿强制结束，以免未完成的录音或录屏无法恢复。'
          : '译学未能确认采集停止或字幕保存完成。可以返回译学，或重试收尾。\n\n$cleanupError';
      final continueCleanup = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          scrollable: true,
          insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          title: const Text('同传收尾未完成'),
          content: Text(content),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('返回译学'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(timedOut ? '继续等待' : '重试收尾'),
            ),
          ],
        ),
      );
      if (continueCleanup != true) {
        await AppExitCleanupRegistry.recordEvent('close_cleanup_user_returned');
        AppExitCleanupRegistry.cancelPendingPreparation();
        return;
      }
      await AppExitCleanupRegistry.recordEvent('close_cleanup_user_continued');
    }
    await _quitWithoutPrompt();
  }

  Future<_SystemShutdownCleanupWait> _waitForSystemShutdownCleanup(
    Future<void> cleanupAttempt, {
    Duration? attemptTimeout,
  }) async {
    final deadline = _systemShutdownCleanupDeadline;
    if (deadline == null) {
      return const _SystemShutdownCleanupWait.deadlineReached();
    }
    final outcomes = <Future<_SystemShutdownCleanupWait>>[
      cleanupAttempt.then<_SystemShutdownCleanupWait>(
        (_) => const _SystemShutdownCleanupWait.completed(),
        onError: (Object error, StackTrace stackTrace) =>
            _SystemShutdownCleanupWait.failed(error, stackTrace),
      ),
      deadline.future.then(
        (_) => const _SystemShutdownCleanupWait.deadlineReached(),
      ),
    ];
    Timer? attemptTimer;
    if (attemptTimeout != null) {
      final attemptTimedOut = Completer<_SystemShutdownCleanupWait>();
      attemptTimer = Timer(
        attemptTimeout,
        () => attemptTimedOut.complete(
          const _SystemShutdownCleanupWait.attemptTimedOut(),
        ),
      );
      outcomes.add(attemptTimedOut.future);
    }
    try {
      return await Future.any(outcomes);
    } finally {
      attemptTimer?.cancel();
    }
  }

  Future<void> _waitForSystemShutdownRetryDelay() async {
    final deadline = _systemShutdownCleanupDeadline;
    if (deadline == null || _systemShutdownCleanupDeadlineElapsed) return;
    final delayElapsed = Completer<void>();
    final timer = Timer(
      _systemShutdownCleanupRetryDelay,
      delayElapsed.complete,
    );
    try {
      await Future.any<void>([delayElapsed.future, deadline.future]);
    } finally {
      timer.cancel();
    }
  }

  Future<void> _prepareExitCleanup() {
    final current = _exitCleanupFuture;
    if (current != null) return current;

    late final Future<void> attempt;
    attempt = () async {
      try {
        await AppExitCleanupRegistry.prepareForExit();
      } finally {
        if (identical(_exitCleanupFuture, attempt)) _exitCleanupFuture = null;
      }
    }();
    _exitCleanupFuture = attempt;
    return attempt;
  }

  Future<void> _quitWithoutPrompt() async {
    if (_isExiting) return;
    _isExiting = true;
    try {
      await _disposeTrayIcon();
      windowManager.removeListener(this);
      _attached = false;
      final processExit = _processExit;
      if (processExit != null) {
        // The native runner owns the final window cleanup. Arm its watchdog
        // before awaiting window-manager methods: those plugin calls have no
        // timeout and could otherwise leave the process hidden but alive.
        await _signalNativeUiCleanupWatchdog();
        // Closing the native window from inside this Flutter method-channel
        // callback can tear down flutter_windows.dll while it is still
        // unwinding. The app has already stopped capture and saved its active
        // session, so let Windows release the remaining process handles.
        processExit();
        return;
      }
      await windowManager.setSkipTaskbar(false);
      await windowManager.setPreventClose(false);
      await windowManager.close();
    } catch (_) {
      _isExiting = false;
      if (Platform.isWindows && !_attached) {
        windowManager.addListener(this);
        _attached = true;
      }
      try {
        await windowManager.setPreventClose(true);
      } catch (_) {
        // The native host may already be tearing down.
      }
      rethrow;
    }
  }

  Future<void> _disposeTrayIcon() async {
    final trayIcon = _trayIcon;
    _trayIcon = null;
    trayIcon?.dispose();
    _trayMenu?.dispose();
    _trayMenu = null;
    _showWindowItem?.dispose();
    _showWindowItem = null;
    _quitItem?.dispose();
    _quitItem = null;
    _trayImage?.dispose();
    _trayImage = null;
  }

  Future<void> _signalNativeUiCleanupWatchdog() async {
    final signal = _nativeCleanupWatchdogSignal;
    if (signal == null) return;
    try {
      final timeout =
          _systemShutdownRequested && !_systemShutdownHasExtendedGrace
          ? const Duration(milliseconds: 400)
          : const Duration(seconds: 2);
      await signal().timeout(timeout);
    } on Object catch (error) {
      // The native runner also signals on WM_DESTROY and message-loop exit.
      // Keep the fallback close path available when running with an older host.
      stderr.writeln('Unable to arm the native close watchdog: $error');
    }
  }

  void _runTrayAction(Future<void> Function() action) {
    unawaited(() async {
      try {
        await action();
      } catch (error) {
        await _showOperationError('无法完成托盘操作', error);
      }
    }());
  }

  Future<void> _showOperationError(String title, Object error) async {
    final context = _navigatorKey.currentContext;
    if (context == null) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SelectableText('$error'),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }
}
