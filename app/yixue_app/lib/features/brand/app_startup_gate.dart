import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:yixue_app/app/app_appearance.dart';
import 'package:yixue_app/features/brand/launch_gate.dart';

typedef AppStartupTask = Future<Widget> Function();
typedef AppStartupReadyCallback = Future<void> Function();
typedef AppStartupErrorBuilder = Widget Function(
  BuildContext context,
  Object error,
  StackTrace stackTrace,
  VoidCallback retry,
  VoidCallback? recover,
);

/// Keeps a visible Flutter frame on screen while desktop startup I/O runs.
///
/// Startup failures stay inside the app so users can retry or choose a
/// different local data directory instead of being left with a blank window.
class AppStartupGate extends StatefulWidget {
  const AppStartupGate({
    required this.start,
    required this.loading,
    required this.errorBuilder,
    required this.recoveryBuilder,
    this.onReady,
    this.startupTimeout = const Duration(seconds: 30),
    this.launchPresentation,
    super.key,
  });

  final AppStartupTask start;
  final Widget loading;
  final AppStartupErrorBuilder errorBuilder;
  final Widget Function() recoveryBuilder;
  final AppStartupReadyCallback? onReady;
  final Duration startupTimeout;
  final ValueListenable<YixueLaunchPresentation>? launchPresentation;

  @override
  State<AppStartupGate> createState() => _AppStartupGateState();
}

class _AppStartupGateState extends State<AppStartupGate> {
  late Future<Widget> _startup;
  late Future<Widget> _startupTask;
  var _startupTaskPending = false;
  var _readyReported = false;
  var _readyReportInFlight = false;
  Widget? _recovery;

  @override
  void initState() {
    super.initState();
    _startup = _start();
  }

  Future<Widget> _start() {
    if (!_startupTaskPending) {
      _startupTask = Future<Widget>.sync(widget.start);
      _startupTaskPending = true;
      // Future.timeout only stops waiting; it does not cancel the operation
      // that owns the app-data lock. Observe its eventual completion so a
      // retry can reuse an in-flight startup instead of starting a second
      // writer against the same stores.
      _startupTask.then<void>(
        (_) {
          _startupTaskPending = false;
          // The timeout future is terminal once it times out. If initialization
          // later succeeds, switch FutureBuilder back to the real task so the
          // app does not remain on a stale timeout page or start a second
          // initializer that competes for the same data lease.
          _startup = _startupTask;
          if (mounted) setState(() {});
        },
        onError: (_, _) {
          _startupTaskPending = false;
          // Surface the actual late failure rather than the expired display
          // timeout; the retry button can then start a fresh attempt safely.
          _startup = _startupTask;
          if (mounted) setState(() {});
        },
      );
    }
    return _startupTask.timeout(
      widget.startupTimeout,
      onTimeout: () =>
          throw TimeoutException('译学启动超过 ${widget.startupTimeout.inSeconds} 秒'),
    );
  }

  void _retry() {
    setState(() {
      _recovery = null;
      _startup = _start();
    });
  }

  void _recover() {
    if (_startupTaskPending) return;
    setState(() => _recovery = widget.recoveryBuilder());
  }

  void _reportReadyAfterFrame() {
    final onReady = widget.onReady;
    if (_readyReported || _readyReportInFlight || onReady == null) return;
    _readyReportInFlight = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        _readyReportInFlight = false;
        return;
      }
      unawaited(_signalReadinessUntilAccepted(onReady));
    });
  }

  Future<void> _signalReadinessUntilAccepted(
    AppStartupReadyCallback onReady,
  ) async {
    var retryDelayMilliseconds = 250;
    while (mounted && !_readyReported) {
      try {
        await onReady();
        if (!mounted) return;
        _readyReported = true;
        _readyReportInFlight = false;
        return;
      } on Object catch (error, stack) {
        debugPrint(
          'App startup readiness notification failed; retrying: $error\n$stack',
        );
        await Future<void>.delayed(
          Duration(milliseconds: retryDelayMilliseconds),
        );
        if (retryDelayMilliseconds < 5000) {
          retryDelayMilliseconds = (retryDelayMilliseconds * 2)
              .clamp(250, 5000)
              .toInt();
        }
      }
    }
    _readyReportInFlight = false;
  }

  @override
  Widget build(BuildContext context) {
    final recovery = _recovery;
    if (recovery != null) return recovery;

    return FutureBuilder<Widget>(
      future: _startup,
      builder: (context, snapshot) {
        // A timeout only ends the gate's wait; the original startup task may
        // still own the data lease. Keep the supervisor's startup deadline in
        // force until that task actually settles and a usable screen is drawn.
        if (snapshot.hasData || (snapshot.hasError && !_startupTaskPending)) {
          _reportReadyAfterFrame();
        }
        final Widget content;
        if (snapshot.hasError) {
          content = widget.errorBuilder(
            context,
            snapshot.error!,
            snapshot.stackTrace ?? StackTrace.current,
            _retry,
            _startupTaskPending ? null : _recover,
          );
        } else {
          content = snapshot.data ?? widget.loading;
        }
        final presentation = widget.launchPresentation;
        if (presentation == null) return content;
        return ValueListenableBuilder<YixueLaunchPresentation>(
          valueListenable: presentation,
          builder: (context, launch, _) => LaunchGate(
            motionLevel: snapshot.hasError
                ? YixueMotionLevel.off
                : launch.motionLevel,
            variant: launch.variant,
            child: content,
          ),
        );
      },
    );
  }
}
