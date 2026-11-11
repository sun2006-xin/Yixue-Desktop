import 'dart:async';

/// Prepares the Windows window plugin with one total deadline so a stalled
/// plugin call cannot prevent [runApp] from mounting the startup experience.
Future<void> prepareMainDesktopWindow({
  required Future<void> Function() initialize,
  required Future<void> Function() configure,
  Duration timeout = const Duration(seconds: 15),
}) async {
  final stopwatch = Stopwatch()..start();
  await initialize().timeout(timeout);
  final remaining = timeout - stopwatch.elapsed;
  if (remaining <= Duration.zero) {
    throw TimeoutException(
      'The Windows window manager did not finish initialization within '
      '${timeout.inSeconds} seconds.',
      timeout,
    );
  }
  await configure().timeout(remaining);
}

/// Reveals the main desktop window only after Flutter has rasterized its first
/// application frame, so the native runner cannot expose an empty surface.
Future<bool> showMainWindowAfterFirstRasterizedFrame({
  required Future<void> firstFrameRasterized,
  required Future<void> Function() prepareWindow,
  required Future<void> Function() showWindow,
  required Future<void> Function() focusWindow,
  required Future<bool> Function() isWindowVisible,
  required Future<bool> Function(Object error, StackTrace stackTrace)
  onPresentationFailure,
  void Function(Object error, StackTrace stackTrace)? onFocusFailure,
  Duration visibilityTimeout = const Duration(seconds: 2),
  Duration windowOperationTimeout = const Duration(seconds: 5),
}) async {
  await firstFrameRasterized;
  try {
    await prepareWindow().timeout(windowOperationTimeout);
    await showWindow().timeout(windowOperationTimeout);
    final visible = await waitForWindowVisibility(
      isWindowVisible: isWindowVisible,
      timeout: visibilityTimeout,
    );
    if (!visible) {
      throw StateError('The native Yixue window did not become visible.');
    }
    try {
      await focusWindow().timeout(windowOperationTimeout);
    } on Object catch (error, stackTrace) {
      onFocusFailure?.call(error, stackTrace);
    }
    return true;
  } on Object catch (error, stackTrace) {
    return onPresentationFailure(
      error,
      stackTrace,
    ).timeout(windowOperationTimeout);
  }
}

Future<bool> waitForWindowVisibility({
  required Future<bool> Function() isWindowVisible,
  Duration timeout = const Duration(seconds: 2),
  Duration pollInterval = const Duration(milliseconds: 25),
}) async {
  final stopwatch = Stopwatch()..start();
  while (true) {
    final remaining = timeout - stopwatch.elapsed;
    if (remaining <= Duration.zero) return false;
    if (await isWindowVisible().timeout(remaining)) return true;
    if (stopwatch.elapsed >= timeout) return false;
    final nextRemaining = timeout - stopwatch.elapsed;
    await Future<void>.delayed(
      nextRemaining < pollInterval ? nextRemaining : pollInterval,
    );
  }
}

Future<void> waitForFirstRasterizedFrame({
  required Future<void> firstFrameRasterized,
  required Duration timeout,
}) => firstFrameRasterized.timeout(
  timeout,
  onTimeout: () => throw TimeoutException(
    'The Flutter window did not rasterize its first frame within '
    '${timeout.inSeconds} seconds.',
  ),
);

/// Holds the supervisor's startup deadline until the app is actually visible.
Future<void> signalSupervisorReadyAfterPresentation({
  required Future<void> windowPresented,
  required Future<void> Function() signalReady,
}) async {
  await windowPresented;
  await signalReady();
}

/// Waits up to [timeout] for presentation, while keeping an observer attached
/// so a late first Flutter frame can still reveal the window and unblock the
/// Windows supervisor if the user chose to keep waiting.
Future<bool?> observeSupervisorWindowPresentation({
  required Future<bool> windowPresentation,
  required Completer<void> supervisorWindowPresented,
  required Duration timeout,
  required Future<void> firstFrameRasterized,
  Future<bool> Function()? isWindowVisible,
  Duration visibilityQueryTimeout = const Duration(seconds: 2),
  Duration visibilityPollInterval = const Duration(milliseconds: 250),
  required void Function() onTimeout,
  required void Function(Object error, StackTrace stackTrace) onFailure,
}) async {
  var failureReported = false;
  void reportFailure(Object error, StackTrace stackTrace) {
    if (failureReported) return;
    failureReported = true;
    onFailure(error, stackTrace);
  }

  Future<void> completeIfPresented() async {
    if (supervisorWindowPresented.isCompleted) return;
    try {
      await firstFrameRasterized;
    } on Object {
      return;
    }
    if (!supervisorWindowPresented.isCompleted) {
      supervisorWindowPresented.complete();
    }
  }

  void observeLateVisibility() {
    final queryVisibility = isWindowVisible;
    if (queryVisibility == null || supervisorWindowPresented.isCompleted) {
      return;
    }

    unawaited(() async {
      try {
        await firstFrameRasterized;
      } on Object {
        return;
      }
      while (!supervisorWindowPresented.isCompleted) {
        Future<bool> visibilityQuery;
        try {
          visibilityQuery = queryVisibility();
        } on Object catch (error, stackTrace) {
          reportFailure(error, stackTrace);
          if (visibilityPollInterval > Duration.zero) {
            await Future<void>.delayed(visibilityPollInterval);
          } else {
            await Future<void>.delayed(Duration.zero);
          }
          continue;
        }
        bool visible;
        try {
          // Keep only one native visibility query in flight. A timed-out
          // MethodChannel call cannot be cancelled; issuing more would queue
          // unbounded work behind a stalled Windows window-manager call. Keep
          // observing that same call so a late native response can still
          // release the supervisor if the user chose to continue waiting.
          visible = await visibilityQuery.timeout(visibilityQueryTimeout);
        } on TimeoutException {
          try {
            visible = await visibilityQuery;
          } on Object catch (error, stackTrace) {
            reportFailure(error, stackTrace);
            visible = false;
          }
        } on Object catch (error, stackTrace) {
          reportFailure(error, stackTrace);
          visible = false;
        }
        if (visible) {
          await completeIfPresented();
          return;
        }
        if (visibilityPollInterval > Duration.zero) {
          await Future<void>.delayed(visibilityPollInterval);
        } else {
          await Future<void>.delayed(Duration.zero);
        }
      }
    }());
  }

  unawaited(
    windowPresentation.then<void>(
      (presented) {
        if (presented) {
          unawaited(completeIfPresented());
        } else {
          observeLateVisibility();
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        reportFailure(error, stackTrace);
        observeLateVisibility();
      },
    ),
  );

  try {
    return await windowPresentation.timeout(timeout);
  } on TimeoutException {
    onTimeout();
    return null;
  } on Object catch (error, stackTrace) {
    reportFailure(error, stackTrace);
    return false;
  }
}
