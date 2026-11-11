import 'dart:async';
import 'dart:ffi' hide Size;
import 'dart:io';
import 'dart:math';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:window_manager/window_manager.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:yixue_app/app/app_theme.dart';
import 'package:yixue_app/core/app_data_directory.dart';
import 'package:yixue_app/core/desktop_window_startup.dart';
import 'package:yixue_app/core/screenshot_dictionary_lookup_history.dart';
import 'package:yixue_app/core/screenshot_translation_window_protocol.dart';
import 'package:yixue_app/core/screenshot_translation_preferences.dart';
import 'package:yixue_app/features/screenshot_translation/screenshot_orb_window.dart';
import 'package:yixue_app/features/screenshot_translation/screenshot_translation_result_window.dart';
import 'package:yixue_app/features/screenshot_translation/screenshot_translation_runtime.dart';

const _messageMethod = 'screenshot_translation_message';
const _childFirstFrameTimeout = Duration(seconds: 8);
const _childActivationAcknowledgementTimeout = Duration(seconds: 10);
const _nativeScreenshotWindowChannel = MethodChannel(
  'yixue/screenshot_translation/native_window',
);

String _channelName(String windowId) =>
    'yixue/screenshot_translation/window/$windowId';

final String _screenshotTranslationHostEpoch =
    '${_readScreenshotTranslationHostClock()}-${Random.secure().nextInt(1 << 32)}';

String _readScreenshotTranslationHostClock() {
  if (Platform.isWindows) {
    final counter = calloc<Int64>();
    try {
      final queryPerformanceCounter = DynamicLibrary.open('kernel32.dll')
          .lookupFunction<
            Int32 Function(Pointer<Int64>),
            int Function(Pointer<Int64>)
          >('QueryPerformanceCounter');
      if (queryPerformanceCounter(counter) == 0) {
        throw StateError('Windows performance counter is unavailable.');
      }
      return 'qpc-${counter.value}';
    } finally {
      calloc.free(counter);
    }
  }
  return 'wall-${DateTime.now().microsecondsSinceEpoch}';
}

Map<String, Object?> _ack(ScreenshotTranslationWindowMessage message) =>
    ScreenshotTranslationWindowMessage(
      type: 'ack',
      requestId: message.requestId,
      payload: const {},
    ).toMap();

@visibleForTesting
bool canRetireScreenshotTranslationChild({
  required Object? activeHostEpoch,
  required int? activeConnectionGeneration,
  required Object? requestedHostEpoch,
  required Object? requestedConnectionGeneration,
}) {
  if (requestedHostEpoch is! String || requestedHostEpoch.isEmpty) {
    return false;
  }
  if (requestedConnectionGeneration != null &&
      (requestedConnectionGeneration is! int ||
          requestedConnectionGeneration <= 0)) {
    return false;
  }
  if (activeHostEpoch == null && activeConnectionGeneration == null) {
    return true;
  }
  if (activeHostEpoch != requestedHostEpoch) return false;
  if (requestedConnectionGeneration == null) {
    return activeConnectionGeneration == null;
  }
  return activeConnectionGeneration == requestedConnectionGeneration;
}

@visibleForTesting
Future<bool> showScreenshotChildWindowUnlessClosing({
  required bool Function() isClosing,
  required Future<void> Function() show,
  required Future<void> Function() hide,
}) async {
  if (isClosing()) return false;
  await show();
  if (!isClosing()) return true;
  try {
    await hide();
  } on Object {
    // The close path may already have destroyed the native window.
  }
  return false;
}

@visibleForTesting
Future<bool> showScreenshotOrbAfterPlacement({
  required Future<void> Function() resize,
  required bool Function() canShow,
  required bool Function() isClosing,
  required Future<void> Function() show,
  required Future<void> Function() hide,
}) async {
  await resize();
  if (!canShow()) return false;
  await show();
  if (canShow()) return true;
  if (!isClosing()) return false;
  try {
    await hide();
  } on Object {
    // Closing may have already destroyed the native window.
  }
  return false;
}

@visibleForTesting
Future<void> activateScreenshotChildAfterFrame({
  required Future<void> firstFrameRasterized,
  required Future<void> Function() activate,
  required Future<void> Function() onFailure,
  bool Function()? canActivate,
  Future<void> Function()? prepare,
  Duration timeout = _childFirstFrameTimeout,
}) async {
  try {
    await prepare?.call();
    await waitForFirstRasterizedFrame(
      firstFrameRasterized: firstFrameRasterized,
      timeout: timeout,
    );
    if (canActivate != null && !canActivate()) {
      throw StateError('Screenshot child closed before activation.');
    }
    await activate();
  } on Object {
    try {
      await onFailure();
    } catch (_) {
      // Preserve the startup error so the parent can retire and replace the
      // child instead of treating cleanup noise as a successful activation.
    }
    rethrow;
  }
}

@visibleForTesting
Future<Map<String, Object?>> acknowledgeScreenshotOrbConfiguredAfterFrame({
  required ScreenshotTranslationWindowMessage message,
  required Future<void> Function() position,
  required Future<void> firstFrameRasterized,
  required Future<void> Function() activate,
  required Future<void> Function() onFailure,
  bool Function()? canActivate,
  bool Function()? isClosing,
  Duration timeout = _childFirstFrameTimeout,
}) async {
  try {
    await position();
    await waitForFirstRasterizedFrame(
      firstFrameRasterized: firstFrameRasterized,
      timeout: timeout,
    );
    if (canActivate != null && !canActivate()) {
      if (isClosing?.call() ?? true) {
        throw StateError('Screenshot orb closed before activation.');
      }
      // A later configuration has already placed the orb. Complete the stale
      // request without activating or retiring that newer placement.
      return _ack(message);
    }
    await activate();
  } on Object {
    try {
      await onFailure();
    } catch (_) {
      // Preserve the startup error so the parent can retire and replace the
      // child instead of treating cleanup noise as a successful activation.
    }
    rethrow;
  }
  return _ack(message);
}

final class ScreenshotTranslationWindowConnectionException
    implements Exception {
  const ScreenshotTranslationWindowConnectionException(this.message);
  final String message;
  @override
  String toString() => message;
}

final class _ScreenshotResultEpochHandshakeRejected implements Exception {
  const _ScreenshotResultEpochHandshakeRejected();
}

/// A live result child belongs to a newer host. Never retire it from this host.
final class _ScreenshotResultHostEpochRetired implements Exception {
  const _ScreenshotResultHostEpochRetired();
}

final class _ScreenshotParentHandlerSuperseded implements Exception {
  const _ScreenshotParentHandlerSuperseded();
}

final class _ScreenshotParentHandlerSlot {
  _ScreenshotParentHandlerSlot({required this.windowId, required this.name});

  final String windowId;
  final String name;
  int ownerGeneration = 0;
  bool registered = false;
  bool quarantined = false;
  Future<Object?> Function(MethodCall)? handler;
  Future<void> _tail = Future<void>.value();

  Future<void> enqueue(Future<void> Function() operation) {
    final next = _tail.then((_) => operation());
    _tail = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  Future<Object?> dispatch(MethodCall call) async {
    final current = handler;
    if (current == null) {
      throw PlatformException(code: 'screenshot_parent_handler_unavailable');
    }
    return current(call);
  }
}

/// A single, identity-checked parent callback registration for one child id.
final class _ScreenshotParentHandlerRegistration {
  _ScreenshotParentHandlerRegistration({
    required this.slot,
    required this.ownerGeneration,
    required this.ready,
  });

  final _ScreenshotParentHandlerSlot slot;
  final int ownerGeneration;
  final Future<void> ready;

  bool get isCurrentOwner => slot.ownerGeneration == ownerGeneration;

  Future<void> release() async {
    if (!isCurrentOwner) return;
    slot.handler = null;
    if (slot.quarantined) return;

    final teardown = slot.enqueue(() async {
      if (!isCurrentOwner || !slot.registered) return;
      await WindowMethodChannel(slot.name)
          .setMethodCallHandler(null)
          .timeout(_ScreenshotParentHandlerRegistry.cleanupTimeout);
      if (isCurrentOwner) slot.registered = false;
    });
    unawaited(
      teardown.then<void>(
        (_) => _ScreenshotParentHandlerRegistry.removeReleasedSlot(
          slot,
          ownerGeneration,
        ),
        onError: (Object _, StackTrace _) {},
      ),
    );
    try {
      await teardown.timeout(_ScreenshotParentHandlerRegistry.cleanupTimeout);
      _ScreenshotParentHandlerRegistry.removeReleasedSlot(
        slot,
        ownerGeneration,
      );
    } on Object {
      // The platform handler API has no cancellation. If registration or
      // unregistration stalls, quarantine this native UUID so it can never be
      // selected by a later connection. A late queued teardown may still
      // finish and reclaim the slot safely.
      slot.quarantined = true;
      _ScreenshotParentHandlerRegistry.quarantine(slot.windowId);
    }
  }
}

final class _ScreenshotParentHandlerRegistry {
  static const cleanupTimeout = Duration(milliseconds: 300);
  static final Map<String, _ScreenshotParentHandlerSlot> _slots = {};
  static final Set<String> _quarantinedWindowIds = {};

  static bool isQuarantined(String windowId) =>
      _quarantinedWindowIds.contains(windowId);

  static void quarantine(String windowId) =>
      _quarantinedWindowIds.add(windowId);

  static void removeReleasedSlot(
    _ScreenshotParentHandlerSlot slot,
    int ownerGeneration,
  ) {
    if (slot.ownerGeneration != ownerGeneration ||
        slot.handler != null ||
        slot.registered) {
      return;
    }
    if (identical(_slots[slot.name], slot)) _slots.remove(slot.name);
    _quarantinedWindowIds.remove(slot.windowId);
    slot.quarantined = false;
  }

  static _ScreenshotParentHandlerRegistration register({
    required String windowId,
    required Future<Object?> Function(MethodCall) handler,
  }) {
    final name = _channelName(windowId);
    if (isQuarantined(windowId)) {
      throw StateError('Screenshot child handler is quarantined.');
    }
    final channel = WindowMethodChannel(name);
    final slot = _slots.putIfAbsent(
      name,
      () => _ScreenshotParentHandlerSlot(windowId: windowId, name: name),
    );
    if (slot.quarantined) {
      throw StateError('Screenshot child handler is quarantined.');
    }
    final ownerGeneration = ++slot.ownerGeneration;
    slot.handler = handler;
    final ready = slot.enqueue(() async {
      if (slot.ownerGeneration != ownerGeneration) {
        throw const _ScreenshotParentHandlerSuperseded();
      }
      if (slot.registered) return;
      await channel.setMethodCallHandler(slot.dispatch);
      // The platform handler belongs to the channel, not to a generation.
      // Even if a newer owner arrived while registration was in flight, mark
      // the shared dispatcher installed so its queued registration reuses it.
      slot.registered = true;
    });
    return _ScreenshotParentHandlerRegistration(
      slot: slot,
      ownerGeneration: ownerGeneration,
      ready: ready,
    );
  }

  @visibleForTesting
  static Future<Object?> dispatchForTesting({
    required String windowId,
    required MethodCall call,
  }) =>
      _slots[_channelName(windowId)]?.dispatch(call) ??
      Future<Object?>.error(
        PlatformException(code: 'screenshot_parent_handler_unavailable'),
      );
}

@visibleForTesting
Future<Object?> dispatchScreenshotTranslationParentMessageForTesting({
  required String windowId,
  required MethodCall call,
}) => _ScreenshotParentHandlerRegistry.dispatchForTesting(
  windowId: windowId,
  call: call,
);

/// A main-engine handle for one child engine and its own bidirectional channel.
final class ScreenshotTranslationWindowSession
    implements ScreenshotTranslationResultHandle, ScreenshotOrbHandle {
  ScreenshotTranslationWindowSession._(
    this.controller, {
    required this._parentHandlerRegistration,
    required this._connectionGeneration,
    required this._hostEpoch,
    required this._activationAcknowledgementTimeout,
  });

  final WindowController controller;
  final _ScreenshotParentHandlerRegistration _parentHandlerRegistration;
  final int _connectionGeneration;
  final String? _hostEpoch;
  final Duration _activationAcknowledgementTimeout;
  int _updateSequence = 0;
  bool _superseded = false;
  // Keep image updates and clears in order even when capture replaces a
  // session while a prior cross-engine message is still awaiting its ACK.
  Future<void> _updateTail = Future.value();
  String? _lastResultSessionId;
  String? _imageBytesSentForSessionId;

  static final _failedChildren = <String>{};
  static final Map<ScreenshotTranslationWindowRole, int>
  _consecutiveStartupFailures = {};
  static final Map<String, int> _resultConnectionGenerations = {};
  static const _maximumConsecutiveStartupFailures = 3;

  static int _nextResultConnectionGeneration(String windowId) =>
      (_resultConnectionGenerations[windowId] ?? 0) + 1;

  static Future<ScreenshotTranslationWindowSession> create({
    required WindowController parent,
    required ScreenshotTranslationWindowRole role,
    Future<ScreenshotTranslationWindowMessage?> Function(
      ScreenshotTranslationWindowMessage,
    )?
    onMessage,
    Duration readinessTimeout = const Duration(seconds: 6),
    Duration activationAcknowledgementTimeout =
        _childActivationAcknowledgementTimeout,
  }) => _create(
    parent: parent,
    role: role,
    onMessage: onMessage,
    readinessTimeout: readinessTimeout,
    activationAcknowledgementTimeout: activationAcknowledgementTimeout,
    retriedIncompatibleChild: false,
  );

  static Future<ScreenshotTranslationWindowSession> _create({
    required WindowController parent,
    required ScreenshotTranslationWindowRole role,
    Future<ScreenshotTranslationWindowMessage?> Function(
      ScreenshotTranslationWindowMessage,
    )?
    onMessage,
    required Duration readinessTimeout,
    required bool retriedIncompatibleChild,
    required Duration activationAcknowledgementTimeout,
  }) async {
    final consecutiveFailures = _consecutiveStartupFailures[role] ?? 0;
    if (consecutiveFailures >= _maximumConsecutiveStartupFailures) {
      throw const ScreenshotTranslationWindowConnectionException(
        'Screenshot child startup stopped after 3 consecutive failures. '
        'Restart the app to retry safely.',
      );
    }
    final elapsed = Stopwatch()..start();
    Duration remaining() {
      final value = readinessTimeout - elapsed.elapsed;
      if (value <= Duration.zero) {
        throw TimeoutException('Screenshot child readiness deadline');
      }
      return value;
    }

    Future<T> withinDeadline<T>(Future<T> work) => work.timeout(remaining());
    WindowController? child;
    _ScreenshotParentHandlerRegistration? parentHandlerRegistration;
    var abandoned = false;
    var resultProbeAttempted = false;
    var resultProbeBudget = Duration.zero;
    String? resultHostEpoch;
    int? resultConnectionGeneration;
    final resultProbeElapsed = Stopwatch();
    Duration probeRemaining() {
      final deadline = remaining();
      if (role != ScreenshotTranslationWindowRole.result ||
          retriedIncompatibleChild) {
        return deadline;
      }
      final available = resultProbeBudget - resultProbeElapsed.elapsed;
      if (available <= Duration.zero) {
        throw TimeoutException('Screenshot result child did not confirm host');
      }
      return available < deadline ? available : deadline;
    }

    try {
      // Resolve the ordered host token before selecting or creating any child.
      // If the clock is unavailable, no existing result child is retired.
      if (role == ScreenshotTranslationWindowRole.result) {
        resultHostEpoch = _screenshotTranslationHostEpoch;
      }
      for (final candidate in await withinDeadline(WindowController.getAll())) {
        if (candidate.arguments.isEmpty ||
            _failedChildren.contains(candidate.windowId) ||
            _ScreenshotParentHandlerRegistry.isQuarantined(
              candidate.windowId,
            )) {
          continue;
        }
        try {
          final arguments = ScreenshotTranslationWindowArguments.decode(
            candidate.arguments,
          );
          if (arguments.parentWindowId == parent.windowId &&
              arguments.role == role) {
            child = candidate;
            break;
          }
        } on FormatException {
          /* Another feature's child. */
        }
      }
      if (child == null) {
        final creation = WindowController.create(
          WindowConfiguration(
            arguments: ScreenshotTranslationWindowArguments(
              role: role,
              parentWindowId: parent.windowId,
            ).encode(),
          ),
        );
        // If creation outlives this attempt, keep the hidden child reusable.
        // It may already be selected by a newer attempt before the native
        // creation future completes, so an unscoped late shutdown is unsafe.
        unawaited(
          creation.then((lateChild) async {
            if (abandoned) {
              debugPrint(
                'Late screenshot child retained for safe reuse: '
                '${lateChild.windowId}',
              );
            }
          }, onError: (Object _, StackTrace _) {}),
        );
        child = await withinDeadline(creation);
      }
      final readyChild = child!;
      final connectionGeneration =
          role == ScreenshotTranslationWindowRole.result
          ? _nextResultConnectionGeneration(readyChild.windowId)
          : 0;
      resultConnectionGeneration = connectionGeneration;
      if (role == ScreenshotTranslationWindowRole.result) {
        _resultConnectionGenerations[readyChild.windowId] =
            connectionGeneration;
      }
      Future<Object?> handleChildMessage(MethodCall call) async {
        if (call.method != _messageMethod) {
          throw MissingPluginException('Unknown child command: ${call.method}');
        }
        final message = ScreenshotTranslationWindowMessage.fromMap(
          call.arguments,
        );
        final response = await onMessage?.call(message);
        return response?.toMap() ?? _ack(message);
      }

      final registration = _ScreenshotParentHandlerRegistry.register(
        windowId: readyChild.windowId,
        handler: handleChildMessage,
      );
      parentHandlerRegistration = registration;
      unawaited(
        registration.ready.then((_) async {
          if (abandoned) await registration.release();
        }, onError: (Object _, StackTrace _) {}),
      );
      await withinDeadline(registration.ready);
      final session = ScreenshotTranslationWindowSession._(
        readyChild,
        parentHandlerRegistration: registration,
        connectionGeneration: connectionGeneration,
        hostEpoch: resultHostEpoch,
        activationAcknowledgementTimeout: activationAcknowledgementTimeout,
      );
      var attempt = 0;
      while (true) {
        if (!resultProbeAttempted) {
          resultProbeAttempted = true;
          final available = remaining();
          // Reserve part of the same readiness deadline for retiring and
          // replacing a child that never responds to the epoch handshake.
          resultProbeBudget =
              role == ScreenshotTranslationWindowRole.result &&
                  !retriedIncompatibleChild
              ? Duration(microseconds: available.inMicroseconds * 2 ~/ 3)
              : available;
          resultProbeElapsed.start();
        }
        final left = probeRemaining();
        try {
          final acknowledgement = await session.send(
            ScreenshotTranslationWindowMessage(
              type: 'probe',
              requestId: 'ready-${attempt++}',
              payload: {
                if (role == ScreenshotTranslationWindowRole.result)
                  'hostEpoch': resultHostEpoch!,
                if (role == ScreenshotTranslationWindowRole.result)
                  'connectionGeneration': connectionGeneration,
              },
            ),
            timeout: left < const Duration(milliseconds: 200)
                ? left
                : const Duration(milliseconds: 200),
          );
          if (role == ScreenshotTranslationWindowRole.result &&
              acknowledgement.payload['hostEpoch'] != resultHostEpoch) {
            if (acknowledgement.payload['errorCode'] == 'stale_update') {
              throw const _ScreenshotResultHostEpochRetired();
            }
            throw const _ScreenshotResultEpochHandshakeRejected();
          }
          // Each child reveals itself after its first positioned payload.
          // In particular, orb readiness must not activate an unplaced window.
          _consecutiveStartupFailures.remove(role);
          return session;
        } on _ScreenshotResultEpochHandshakeRejected {
          rethrow;
        } on _ScreenshotResultHostEpochRetired {
          rethrow;
        } catch (_) {
          final left = probeRemaining();
          await Future<void>.delayed(
            left < const Duration(milliseconds: 25)
                ? left
                : const Duration(milliseconds: 25),
          );
        }
      }
    } catch (error) {
      abandoned = true;
      if (error is _ScreenshotParentHandlerSuperseded) {
        await parentHandlerRegistration?.release();
        throw const ScreenshotTranslationWindowConnectionException(
          'Child callback was superseded by a newer window connection',
        );
      }
      if (error is _ScreenshotResultHostEpochRetired) {
        // This child has already accepted a newer host. Release is scoped to
        // this attempt's callback token and cannot detach a newer handler.
        try {
          await parentHandlerRegistration?.release();
        } catch (_) {
          // The rejected connection is isolated from the active child.
        }
        throw const ScreenshotTranslationWindowConnectionException(
          'Result child belongs to a newer host epoch',
        );
      }
      Object? cleanupError;
      if (child != null) {
        try {
          final retired = await _retireChild(
            child,
            parentHandlerRegistration,
            hostEpoch: resultHostEpoch,
            connectionGeneration: resultConnectionGeneration,
          );
          if (retired) {
            _failedChildren.add(child.windowId);
            _consecutiveStartupFailures[role] =
                (_consecutiveStartupFailures[role] ?? 0) + 1;
          } else {
            cleanupError = StateError(
              'Child is owned by a newer result connection.',
            );
          }
        } catch (error) {
          cleanupError = error;
          // Cleanup timed out, so this child must never be selected again even
          // if native enumeration continues to report it as alive.
          _failedChildren.add(child.windowId);
          _consecutiveStartupFailures[role] =
              (_consecutiveStartupFailures[role] ?? 0) + 1;
        }
      }
      final recoverStaleOrUnresponsiveResultChild =
          role == ScreenshotTranslationWindowRole.result &&
          !retriedIncompatibleChild &&
          (error is _ScreenshotResultEpochHandshakeRejected ||
              (resultProbeAttempted && error is TimeoutException));
      if (recoverStaleOrUnresponsiveResultChild && cleanupError == null) {
        try {
          return await _create(
            parent: parent,
            role: role,
            onMessage: onMessage,
            readinessTimeout: remaining(),
            retriedIncompatibleChild: true,
            activationAcknowledgementTimeout: activationAcknowledgementTimeout,
          );
        } on TimeoutException {
          // Preserve the original readiness failure and cleanup context.
        }
      }
      throw ScreenshotTranslationWindowConnectionException(
        cleanupError == null
            ? 'Child readiness failed: $error'
            : 'Child readiness failed: $error; child cleanup failed: $cleanupError',
      );
    }
  }

  static Future<bool> _retireChild(
    WindowController child,
    _ScreenshotParentHandlerRegistration? parentHandlerRegistration, {
    String? hostEpoch,
    int? connectionGeneration,
  }) async {
    if (parentHandlerRegistration != null &&
        !parentHandlerRegistration.isCurrentOwner) {
      return false;
    }
    final cleanup = Stopwatch()..start();
    const limit = Duration(seconds: 1);
    Duration left() {
      final remaining = limit - cleanup.elapsed;
      if (remaining <= Duration.zero) {
        throw TimeoutException('Child cleanup deadline');
      }
      return remaining;
    }

    try {
      while (true) {
        final message = ScreenshotTranslationWindowMessage(
          type: 'shutdownRequested',
          requestId: 'retire-${child.windowId}',
          payload: hostEpoch != null
              ? {
                  'hostEpoch': hostEpoch,
                  if (connectionGeneration != null)
                    'connectionGeneration': connectionGeneration,
                }
              : const {},
        );
        try {
          final available = left();
          final response = await child
              .invokeMethod<Object?>(_messageMethod, message.toMap())
              .timeout(
                available < const Duration(milliseconds: 100)
                    ? available
                    : const Duration(milliseconds: 100),
              );
          if (hostEpoch != null) {
            final acknowledgement = ScreenshotTranslationWindowMessage.fromMap(
              response,
            );
            if (acknowledgement.payload['retired'] == false) return false;
          }
        } catch (_) {
          /* Early lifecycle registration may still be finishing. */
        }
        final alive = await WindowController.getAll().timeout(left());
        if (!alive.any((candidate) => candidate.windowId == child.windowId)) {
          return true;
        }
        final remaining = left();
        await Future<void>.delayed(
          remaining < const Duration(milliseconds: 20)
              ? remaining
              : const Duration(milliseconds: 20),
        );
      }
    } finally {
      try {
        await parentHandlerRegistration?.release();
      } catch (_) {
        // Handler cleanup is best effort; retirement remains independently
        // bounded by the child-window deadline.
      }
    }
  }

  Future<ScreenshotTranslationWindowMessage> send(
    ScreenshotTranslationWindowMessage message, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final response = await controller
        .invokeMethod<Object?>(_messageMethod, message.toMap())
        .timeout(timeout);
    final acknowledgement = ScreenshotTranslationWindowMessage.fromMap(
      response,
    );
    if (acknowledgement.type != 'ack' ||
        acknowledgement.requestId != message.requestId) {
      throw const FormatException('Screenshot child acknowledgement mismatch');
    }
    return acknowledgement;
  }

  @override
  Future<void> update(ScreenshotTranslationSession? session) {
    final done = _updateTail.then<void>(
      (_) => _sendUpdate(session),
      onError: (Object _, StackTrace _) => _sendUpdate(session),
    );
    _updateTail = done;
    return done;
  }

  Future<void> _sendUpdate(ScreenshotTranslationSession? session) async {
    if (_superseded) {
      throw const ScreenshotTranslationResultHandleSupersededException();
    }
    final sessionId = session?.id;
    final updateSequence = ++_updateSequence;
    final canReuseImageBytes =
        session != null &&
        session.imageBytes != null &&
        session.id == _lastResultSessionId &&
        session.id == _imageBytesSentForSessionId;
    Future<ScreenshotTranslationWindowMessage> sendUpdate({
      required bool includeImageBytes,
      required bool reuseImageBytes,
    }) => send(
      ScreenshotTranslationWindowMessage(
        type: 'sessionUpdated',
        requestId: sessionId ?? 'closed',
        payload: {
          'session': session?.toMap(includeImageBytes: includeImageBytes),
          'hostEpoch': _screenshotTranslationHostEpoch,
          'connectionGeneration': _connectionGeneration,
          'updateSequence': updateSequence,
          if (reuseImageBytes) 'reuseImageForSessionId': sessionId,
        },
      ),
      timeout: _activationAcknowledgementTimeout,
    );

    try {
      final acknowledgement = await sendUpdate(
        includeImageBytes: !canReuseImageBytes,
        reuseImageBytes: canReuseImageBytes,
      );
      if (acknowledgement.payload['errorCode'] == 'stale_update') {
        _markSuperseded();
        throw const ScreenshotTranslationResultHandleSupersededException();
      }
      final reuseWasConfirmed =
          acknowledgement.payload['imageReusedForSessionId'] == sessionId;
      if (acknowledgement.payload['errorCode'] == 'result_image_cache_miss' ||
          (canReuseImageBytes && !reuseWasConfirmed)) {
        // The child restarted or lost its session state; recover by sending
        // the complete image before acknowledging this update to the caller.
        // An older child that ignores the reuse marker also takes this path.
        final recovery = await sendUpdate(
          includeImageBytes: true,
          reuseImageBytes: false,
        );
        if (recovery.payload['errorCode'] == 'stale_update') {
          _markSuperseded();
          throw const ScreenshotTranslationResultHandleSupersededException();
        }
      }
    } on ScreenshotTranslationResultHandleSupersededException {
      _resetImageCache();
      rethrow;
    } catch (error, stackTrace) {
      // The child may have applied the update before its ACK was lost. Force
      // the next update to include image bytes so either child state is valid.
      // Retire this child as well: it must not reveal an old session after the
      // parent has already declared the connection failed.
      _resetImageCache();
      try {
        await close();
      } catch (_) {
        // The child enforces its own shorter first-frame cleanup deadline.
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
    _lastResultSessionId = sessionId;
    _imageBytesSentForSessionId = session?.imageBytes == null
        ? null
        : sessionId;
  }

  void _resetImageCache() {
    _lastResultSessionId = null;
    _imageBytesSentForSessionId = null;
  }

  void _markSuperseded() {
    _superseded = true;
    _resetImageCache();
  }

  @override
  Future<void> hide() => controller.hide();

  @override
  Future<void> open(ScreenshotOrbPosition? position) async {
    try {
      await send(
        ScreenshotTranslationWindowMessage(
          type: 'orbConfigured',
          requestId: 'orb-${DateTime.now().microsecondsSinceEpoch}',
          payload: {'position': position?.toJson()},
        ),
        timeout: _activationAcknowledgementTimeout,
      );
    } catch (error, stackTrace) {
      try {
        await close();
      } catch (_) {
        // The child enforces its own shorter first-frame cleanup deadline.
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  @override
  Future<void> close() async {
    await _retireChild(
      controller,
      _parentHandlerRegistration,
      hostEpoch: _hostEpoch,
      connectionGeneration: _hostEpoch == null ? null : _connectionGeneration,
    );
  }

  static Future<void> closeAll(
    WindowController parent, {
    Duration enumerationTimeout = const Duration(seconds: 5),
  }) async {
    Object? firstError;
    // Window enumeration crosses a platform channel and can hang when a child
    // engine is already shutting down. Bound this read-only probe so the main
    // close flow can show its recovery prompt and retry instead of waiting
    // forever. No child is retired when enumeration itself cannot be trusted.
    final children = await WindowController.getAll().timeout(
      enumerationTimeout,
      onTimeout: () => throw TimeoutException(
        'Screenshot child window enumeration did not finish.',
        enumerationTimeout,
      ),
    );
    for (final candidate in children) {
      try {
        final args = ScreenshotTranslationWindowArguments.decode(
          candidate.arguments,
        );
        if (args.parentWindowId == parent.windowId) {
          final retired = await _retireChild(candidate, null);
          if (!retired) {
            firstError ??= StateError(
              'Screenshot child is still owned by an active connection.',
            );
          }
        }
      } on FormatException {
        /* Main or another feature's window. */
      } catch (error) {
        firstError ??= error;
      }
    }
    if (firstError != null) {
      throw StateError('Screenshot child shutdown failed');
    }
  }
}

/// This entry is run only by a child engine; it never opens the app database.
Future<void> runScreenshotTranslationChildWindow(
  WindowController controller,
) async {
  final lifecycle = _ScreenshotChildLifecycle(controller);
  try {
    // Register shutdown before any plugin/UI initialization can fail or await.
    await lifecycle.initialize();
    await windowManager.ensureInitialized();
    // The Windows window_manager plugin creates its taskbar COM object here.
    // Child windows call setSkipTaskbar during role setup, so they must perform
    // this readiness step themselves instead of relying on the main engine.
    await windowManager.waitUntilReadyToShow();
    final arguments = ScreenshotTranslationWindowArguments.decode(
      controller.arguments,
    );
    if (arguments.role == ScreenshotTranslationWindowRole.result) {
      await _runResultWindow(controller, lifecycle);
      return;
    }
    if (arguments.role == ScreenshotTranslationWindowRole.orb) {
      await _runOrbWindow(controller, lifecycle);
      return;
    }
    if (lifecycle.closing) return;
    lifecycle.delegate = (call) async {
      if (call.method != _messageMethod) {
        throw MissingPluginException('Unknown parent command: ${call.method}');
      }
      final message = ScreenshotTranslationWindowMessage.fromMap(
        call.arguments,
      );
      return ScreenshotTranslationWindowMessage(
        type: 'ack',
        requestId: message.requestId,
        payload: const {},
      ).toMap();
    };
    runApp(_ChildProbeApp(role: arguments.role, channel: lifecycle.channel));
    await waitForFirstRasterizedFrame(
      firstFrameRasterized:
          WidgetsBinding.instance.waitUntilFirstFrameRasterized,
      timeout: _childFirstFrameTimeout,
    );
    await controller.show();
  } catch (error) {
    try {
      await lifecycle.cleanup();
    } catch (cleanupError) {
      // Parent readiness failure remains visible; never activate a failed child.
      debugPrint(
        'Screenshot child startup/cleanup failed: $error; $cleanupError',
      );
    }
  }
}

/// Construct only in the main engine. A child never calls this adapter.
final class MainEngineScreenshotHotKey implements ScreenshotGlobalHotKey {
  HotKey? _registered;
  @override
  Future<void> register(ScreenshotHotKey key, VoidCallback onPressed) async {
    final hotKey = HotKey(
      identifier: 'yixue-screenshot-global',
      key: key.key,
      modifiers: key.modifiers
          .map((v) => HotKeyModifier.values.byName(v))
          .toList(),
      scope: HotKeyScope.system,
    );
    try {
      await hotKeyManager.register(hotKey, keyDownHandler: (_) => onPressed());
      _registered = hotKey;
    } on PlatformException catch (error) {
      throw ScreenshotHotKeyRegistrationException(
        error.code,
        error.details is int ? error.details as int : null,
      );
    }
  }

  @override
  Future<void> unregister() async {
    final key = _registered;
    if (key == null) return;
    await hotKeyManager.unregister(key);
    _registered = null;
  }
}

Future<void> _runOrbWindow(
  WindowController controller,
  _ScreenshotChildLifecycle lifecycle,
) async {
  final orbWindowSize = screenshotOrbWindowSizeForMode(
    ScreenshotOrbWindowMode.orb,
  );
  await windowManager.setAsFrameless();
  await windowManager.setBackgroundColor(Colors.transparent);
  await windowManager.setMinimumSize(orbWindowSize);
  await windowManager.setSize(orbWindowSize);
  await windowManager.setResizable(false);
  await windowManager.setSkipTaskbar(true);
  if (Platform.isWindows) {
    // This frameless child is a transparent 56px orb, so the desktop window
    // itself must not add a rectangular DWM shadow around its transparent area.
    await windowManager.setHasShadow(false);
    // Keep clicks in Flutter while preventing the orb from replacing the
    // foreground application that the native capture plugin must restore.
    await _nativeScreenshotWindowChannel.invokeMethod<void>('setNoActivate');
  }
  final native = Platform.isWindows
      ? await _InactiveWindowsWindow.find(controller.windowId)
      : null;
  native?.topmost(true);
  if (native == null) await windowManager.setAlwaysOnTop(true);
  final contentOffset = ValueNotifier<Offset>(Offset.zero);
  var anchor = Offset.zero;
  var scale = 1.0;
  var placementGeneration = 0;
  List<ScreenshotOrbDisplay> displays = [];
  Future<void> readDisplays() async {
    displays = (await screenRetriever.getAllDisplays())
        .map(
          (display) => ScreenshotOrbDisplay(
            _displayPhysicalRect(display),
            display.scaleFactor?.toDouble() ?? 1,
          ),
        )
        .toList();
    if (displays.isEmpty) throw StateError('No orb work area');
  }

  ScreenshotOrbDisplay displayAt(Offset point) => displays.reduce((a, b) {
    double distance(Rect rect) =>
        (point -
                Offset(
                  point.dx.clamp(rect.left, rect.right).toDouble(),
                  point.dy.clamp(rect.top, rect.bottom).toDouble(),
                ))
            .distanceSquared;
    return distance(a.workArea) <= distance(b.workArea) ? a : b;
  });
  Future<void> resize(ScreenshotOrbWindowMode mode) async {
    if (lifecycle.closing) return;
    final logical = screenshotOrbWindowSizeForMode(mode);
    final area = displayAt(anchor).workArea;
    final layout = layoutScreenshotOrbWindow(
      anchor: anchor,
      workArea: area,
      scale: scale,
      logicalSize: logical,
    );
    if (native != null) {
      // Move and resize as one Win32 operation so the pointer cannot fall
      // outside the temporarily mis-sized window and toggle hover repeatedly.
      native.place(layout.origin, layout.physicalSize);
    } else {
      await windowManager.setPosition(layout.origin / scale);
      await windowManager.setSize(logical);
    }
    contentOffset.value = layout.contentOffset;
  }

  Future<void> command(
    String type, [
    Map<String, Object?> payload = const {},
  ]) async {
    if (lifecycle.closing) return;
    final message = ScreenshotTranslationWindowMessage(
      type: type,
      requestId: 'orb-${DateTime.now().microsecondsSinceEpoch}',
      payload: payload,
    );
    final raw = await lifecycle.channel
        .invokeMethod<Object?>(_messageMethod, message.toMap())
        .timeout(const Duration(seconds: 5));
    final ack = ScreenshotTranslationWindowMessage.fromMap(raw);
    if (ack.type != 'ack' || ack.requestId != message.requestId) {
      throw const FormatException('Orb command acknowledgement mismatch');
    }
  }

  Future<int?> snap(
    Offset position, {
    bool persist = false,
    bool showWindow = true,
  }) async {
    final generation = ++placementGeneration;
    await readDisplays();
    if (lifecycle.closing || generation != placementGeneration) return null;
    anchor = snapScreenshotOrb(position, displays);
    scale = displayAt(anchor).scale;
    if (showWindow) {
      await showScreenshotOrbAfterPlacement(
        resize: () => resize(ScreenshotOrbWindowMode.orb),
        canShow: () => !lifecycle.closing && generation == placementGeneration,
        isClosing: () => lifecycle.closing,
        show: () async {
          if (native != null) {
            native.show();
          } else {
            await windowManager.show(inactive: true);
          }
        },
        hide: windowManager.hide,
      );
    } else {
      await resize(ScreenshotOrbWindowMode.orb);
    }
    if (lifecycle.closing || generation != placementGeneration) return null;
    if (persist) await command('orbMoved', {'x': anchor.dx, 'y': anchor.dy});
    if (lifecycle.closing || generation != placementGeneration) return null;
    return generation;
  }

  await readDisplays();
  if (lifecycle.closing) return;
  final firstFrameRasterized =
      WidgetsBinding.instance.waitUntilFirstFrameRasterized;
  lifecycle.delegate = (call) async {
    if (call.method != _messageMethod) throw MissingPluginException();
    final message = ScreenshotTranslationWindowMessage.fromMap(call.arguments);
    if (message.type == 'orbConfigured') {
      final value = message.payload['position'];
      final primary = displays.first;
      final initial = Offset(
        primary.workArea.right - ScreenshotOrbWindow.diameter * primary.scale,
        primary.workArea.center.dy,
      );
      final requested = value is Map && value['x'] is num && value['y'] is num
          ? Offset(
              (value['x'] as num).toDouble(),
              (value['y'] as num).toDouble(),
            )
          : initial;
      int? configuredGeneration;
      return acknowledgeScreenshotOrbConfiguredAfterFrame(
        message: message,
        position: () async {
          configuredGeneration = await snap(requested, showWindow: false);
        },
        firstFrameRasterized: firstFrameRasterized,
        canActivate: () =>
            !lifecycle.closing &&
            configuredGeneration != null &&
            configuredGeneration == placementGeneration,
        isClosing: () => lifecycle.closing,
        activate: () => showScreenshotOrbAfterPlacement(
          resize: () => resize(ScreenshotOrbWindowMode.orb),
          canShow: () =>
              !lifecycle.closing &&
              configuredGeneration != null &&
              configuredGeneration == placementGeneration,
          isClosing: () => lifecycle.closing,
          show: () async {
            if (native != null) {
              native.show();
            } else {
              await windowManager.show(inactive: true);
            }
          },
          hide: windowManager.hide,
        ).then<void>((_) {}),
        onFailure: lifecycle.cleanup,
      );
    }
    return _ack(message);
  };
  lifecycle.releaseSession = () => placementGeneration++;
  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      home: Material(
        type: MaterialType.transparency,
        child: ValueListenableBuilder<Offset>(
          valueListenable: contentOffset,
          builder: (context, offset, _) => Stack(
            children: [
              Positioned(
                left: offset.dx,
                top: offset.dy,
                child: ScreenshotOrbWindow(
                  onCapture: () => unawaited(
                    command('captureRequested').catchError((Object _) {}),
                  ),
                  onMenu: (action) {
                    final type = switch (action) {
                      ScreenshotOrbMenuAction.capture => 'captureRequested',
                      ScreenshotOrbMenuAction.dictionaryLookup =>
                        'openDictionaryLookup',
                      ScreenshotOrbMenuAction.openMain => 'openMain',
                      ScreenshotOrbMenuAction.shortcutSettings =>
                        'openScreenshotSettings',
                      ScreenshotOrbMenuAction.disableOrb => 'disableOrb',
                      ScreenshotOrbMenuAction.quit => 'quitRequested',
                      ScreenshotOrbMenuAction.dismiss => null,
                    };
                    if (type != null) {
                      unawaited(command(type).catchError((Object _) {}));
                    }
                  },
                  beforeMenu: () async {
                    await resize(ScreenshotOrbWindowMode.contextMenu);
                  },
                  afterMenu: () async {
                    await resize(ScreenshotOrbWindowMode.orb);
                  },
                  onDrag: () async {
                    await resize(ScreenshotOrbWindowMode.orb);
                    await windowManager.startDragging();
                    if (!lifecycle.closing) {
                      final position =
                          native?.readPosition() ??
                          (await windowManager.getPosition()) * scale;
                      await snap(position, persist: true);
                    }
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

final class _ScreenshotChildLifecycle {
  _ScreenshotChildLifecycle(this.controller)
    : channel = WindowMethodChannel(_channelName(controller.windowId)) {
    canRetireOwnedChild = (message) => canRetireScreenshotTranslationChild(
      activeHostEpoch: null,
      activeConnectionGeneration: null,
      requestedHostEpoch: message.payload['hostEpoch'],
      requestedConnectionGeneration: message.payload['connectionGeneration'],
    );
  }
  final WindowController controller;
  final WindowMethodChannel channel;
  Future<Object?> Function(MethodCall)? delegate;
  VoidCallback? releaseSession;
  bool Function(ScreenshotTranslationWindowMessage)? canRetireOwnedChild;
  bool closing = false;
  Future<void>? _cleanup;

  Future<void> initialize() async {
    await controller.setWindowMethodHandler(receive);
    await channel.setMethodCallHandler(receive);
  }

  Future<Object?> receive(MethodCall call) async {
    if (call.method != _messageMethod) throw MissingPluginException();
    final message = ScreenshotTranslationWindowMessage.fromMap(call.arguments);
    if (message.type == 'shutdownRequested') {
      final isOwnedRetirement =
          message.payload.containsKey('hostEpoch') ||
          message.payload.containsKey('connectionGeneration');
      if (isOwnedRetirement && !(canRetireOwnedChild?.call(message) ?? false)) {
        return ScreenshotTranslationWindowMessage(
          type: 'ack',
          requestId: message.requestId,
          payload: const {'retired': false},
        ).toMap();
      }
      closing = true;
      // Let the ACK leave the engine before removing its channel/closing HWND.
      unawaited(
        Future<void>.delayed(Duration.zero, cleanup).catchError((Object error) {
          debugPrint('Screenshot child requested cleanup failed: $error');
        }),
      );
      return ScreenshotTranslationWindowMessage(
        type: 'ack',
        requestId: message.requestId,
        payload: isOwnedRetirement ? const {'retired': true} : const {},
      ).toMap();
    }
    if (closing || delegate == null) {
      throw PlatformException(code: 'child_starting');
    }
    return delegate!(call);
  }

  Future<void> cleanup() => _cleanup ??= _close();

  Future<void> _close() async {
    closing = true;
    delegate = null;
    releaseSession?.call();
    runApp(const SizedBox.shrink());
    Object? firstError;
    for (final action in <Future<void> Function()>[
      () => channel.setMethodCallHandler(null),
      () => controller.setWindowMethodHandler(null),
      () => windowManager.setPreventClose(false),
      // destroy() posts WM_QUIT and would terminate all windows on Windows.
      () => windowManager.close(),
    ]) {
      try {
        await action().timeout(const Duration(milliseconds: 200));
      } catch (error) {
        firstError ??= error;
      }
    }
    if (firstError != null) {
      throw StateError('Screenshot child cleanup failed: $firstError');
    }
  }
}

/// Closing this window allows the main window to create a fresh child.
final class ScreenshotTranslationWindowStartupError extends StatelessWidget {
  const ScreenshotTranslationWindowStartupError({
    required this.message,
    super.key,
  });

  final String message;

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('截屏翻译窗口启动失败'),
              const SizedBox(height: 12),
              SelectableText(message),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => windowManager.close(),
                child: const Text('关闭窗口，从主窗口重试'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

final class _ChildProbeApp extends StatefulWidget {
  const _ChildProbeApp({required this.role, required this.channel});

  final ScreenshotTranslationWindowRole role;
  final WindowMethodChannel channel;

  @override
  State<_ChildProbeApp> createState() => _ChildProbeAppState();
}

final class _ChildProbeAppState extends State<_ChildProbeApp> {
  String _status = '消息通道已准备';

  Future<void> _pingMain() async {
    final request = ScreenshotTranslationWindowMessage(
      type: 'probe',
      requestId: DateTime.now().microsecondsSinceEpoch.toString(),
      payload: {'role': widget.role.name},
    );
    try {
      final raw = await widget.channel.invokeMethod<Object?>(
        _messageMethod,
        request.toMap(),
      );
      final response = ScreenshotTranslationWindowMessage.fromMap(raw);
      if (mounted) {
        setState(
          () => _status =
              response.type == 'ack' && response.requestId == request.requestId
              ? '主窗口已确认'
              : '主窗口返回了无效确认',
        );
      }
    } catch (error) {
      if (mounted) setState(() => _status = '连接失败：$error');
    }
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('截屏翻译 ${widget.role.name} 窗口'),
            const SizedBox(height: 12),
            Text(_status),
            const SizedBox(height: 12),
            FilledButton(onPressed: _pingMain, child: const Text('检查主窗口连接')),
          ],
        ),
      ),
    ),
  );
}

Future<void> _runResultWindow(
  WindowController controller,
  _ScreenshotChildLifecycle lifecycle,
) async {
  final hostEpoch = ScreenshotTranslationWindowHostEpoch();
  int? activeConnectionGeneration;
  lifecycle.canRetireOwnedChild = (message) {
    return canRetireScreenshotTranslationChild(
      activeHostEpoch: hostEpoch.active,
      activeConnectionGeneration: activeConnectionGeneration,
      requestedHostEpoch: message.payload['hostEpoch'],
      requestedConnectionGeneration: message.payload['connectionGeneration'],
    );
  };
  final lookupHistoryStore = await _screenshotDictionaryLookupHistoryStore();
  final session = ValueNotifier<ScreenshotTranslationSession?>(null);
  var updateGeneration = 0;
  var firstFramePresented = false;
  final firstFrameRasterized =
      WidgetsBinding.instance.waitUntilFirstFrameRasterized;
  final channel = lifecycle.channel;
  lifecycle.releaseSession = () {
    updateGeneration++;
    session.value = null;
  };
  var sessionUpdateTail = Future<void>.value();
  ScreenshotTranslationWindowUpdateStamp? lastAcceptedUpdate;
  await windowManager.setTitleBarStyle(
    TitleBarStyle.hidden,
    windowButtonVisibility: false,
  );
  await windowManager.setMinimumSize(const Size(420, 300));
  await windowManager.setSize(const Size(560, 400));
  await windowManager.setSkipTaskbar(true);
  await windowManager.setPreventClose(true);
  // Windows window_manager ignores show(inactive:true); use the exact child
  // HWND and SW_SHOWNOACTIVATE so the original application retains input.
  final nativeWindow = Platform.isWindows
      ? await _InactiveWindowsWindow.find(controller.windowId)
      : null;
  if (lifecycle.closing) return;
  if (nativeWindow != null) {
    nativeWindow.topmost(true);
  } else {
    await windowManager.setAlwaysOnTop(true);
  }
  Future<Object?> applyMessage(
    ScreenshotTranslationWindowMessage message,
  ) async {
    String? reusedImageSessionId;
    if (message.type == 'probe') {
      final requestedHostEpoch = message.payload['hostEpoch'];
      final requestedConnectionGeneration =
          message.payload['connectionGeneration'];
      if (requestedHostEpoch is! String ||
          requestedHostEpoch.isEmpty ||
          requestedConnectionGeneration is! int ||
          requestedConnectionGeneration <= 0) {
        return _ack(message);
      }
      if (lifecycle.closing) {
        return ScreenshotTranslationWindowMessage(
          type: 'ack',
          requestId: message.requestId,
          payload: const {'errorCode': 'stale_update'},
        ).toMap();
      }
      final claim = hostEpoch.claim(requestedHostEpoch);
      if (claim == ScreenshotTranslationHostEpochClaim.retired ||
          (claim == ScreenshotTranslationHostEpochClaim.unchanged &&
              activeConnectionGeneration != null &&
              requestedConnectionGeneration < activeConnectionGeneration!)) {
        return ScreenshotTranslationWindowMessage(
          type: 'ack',
          requestId: message.requestId,
          payload: const {'errorCode': 'stale_update'},
        ).toMap();
      }
      final newConnection =
          claim == ScreenshotTranslationHostEpochClaim.activated ||
          activeConnectionGeneration == null ||
          requestedConnectionGeneration > activeConnectionGeneration!;
      if (newConnection) {
        activeConnectionGeneration = requestedConnectionGeneration;
        final hadSession = session.value != null;
        lastAcceptedUpdate = null;
        updateGeneration++;
        session.value = null;
        if (hadSession) await windowManager.hide();
        if (lifecycle.closing) {
          return ScreenshotTranslationWindowMessage(
            type: 'ack',
            requestId: message.requestId,
            payload: const {'errorCode': 'stale_update'},
          ).toMap();
        }
      }
      return ScreenshotTranslationWindowMessage(
        type: 'ack',
        requestId: message.requestId,
        payload: {
          'hostEpoch': hostEpoch.active,
          'connectionGeneration': activeConnectionGeneration,
        },
      ).toMap();
    }
    if (message.type == 'sessionUpdated') {
      if (!hostEpoch.accepts(message.payload['hostEpoch'])) {
        return ScreenshotTranslationWindowMessage(
          type: 'ack',
          requestId: message.requestId,
          payload: const {'errorCode': 'stale_update'},
        ).toMap();
      }
      final connectionGeneration = message.payload['connectionGeneration'];
      final updateSequence = message.payload['updateSequence'];
      if (connectionGeneration is! int ||
          connectionGeneration <= 0 ||
          updateSequence is! int ||
          updateSequence <= 0) {
        return ScreenshotTranslationWindowMessage(
          type: 'ack',
          requestId: message.requestId,
          payload: const {'errorCode': 'invalid_update_order'},
        ).toMap();
      }
      if (connectionGeneration != activeConnectionGeneration) {
        return ScreenshotTranslationWindowMessage(
          type: 'ack',
          requestId: message.requestId,
          payload: const {'errorCode': 'stale_update'},
        ).toMap();
      }
      final updateStamp = ScreenshotTranslationWindowUpdateStamp(
        connectionGeneration: connectionGeneration,
        updateSequence: updateSequence,
      );
      final previousAcceptedUpdate = lastAcceptedUpdate;
      if (previousAcceptedUpdate != null &&
          !updateStamp.isAfter(previousAcceptedUpdate)) {
        return ScreenshotTranslationWindowMessage(
          type: 'ack',
          requestId: message.requestId,
          payload: const {'errorCode': 'stale_update'},
        ).toMap();
      }

      final value = message.payload['session'];
      final previous = session.value;
      final reuseImageForSessionId = message.payload['reuseImageForSessionId'];
      final reusesPreviousImage =
          value is Map &&
          reuseImageForSessionId is String &&
          value['id'] == reuseImageForSessionId &&
          previous?.id == reuseImageForSessionId &&
          previous?.imageBytes != null;
      if (value is Map &&
          !value.containsKey('imageBytes') &&
          !reusesPreviousImage) {
        return ScreenshotTranslationWindowMessage(
          type: 'ack',
          requestId: message.requestId,
          payload: const {'errorCode': 'result_image_cache_miss'},
        ).toMap();
      }
      lastAcceptedUpdate = updateStamp;
      final generation = ++updateGeneration;
      final next = value is Map
          ? ScreenshotTranslationSession.fromMap(
              value,
              previous: reusesPreviousImage ? previous : null,
            )
          : null;
      if (reusesPreviousImage) {
        reusedImageSessionId = reuseImageForSessionId;
      }
      final previousId = previous?.id;
      session.value = next;
      if (next == null) {
        await windowManager.hide();
        if (lifecycle.closing || generation != updateGeneration) {
          return ScreenshotTranslationWindowMessage(
            type: 'ack',
            requestId: message.requestId,
            payload: const {'errorCode': 'stale_update'},
          ).toMap();
        }
      } else {
        if (next.id != previousId && next.bounds != null) {
          final position = await screenshotResultPlacement(
            selection: Rect.fromLTWH(
              next.bounds!.left.toDouble(),
              next.bounds!.top.toDouble(),
              next.bounds!.width.toDouble(),
              next.bounds!.height.toDouble(),
            ),
            readLogicalSize: windowManager.getSize,
            readDisplays: screenRetriever.getAllDisplays,
            isCurrent: () =>
                !lifecycle.closing &&
                generation == updateGeneration &&
                session.value?.id == next.id,
          );
          if (position != null) {
            if (nativeWindow != null) {
              nativeWindow.position(position);
            } else {
              final ratio = WidgetsBinding
                  .instance
                  .platformDispatcher
                  .views
                  .first
                  .devicePixelRatio;
              await windowManager.setPosition(position / ratio);
            }
          }
        }
        if (generation != updateGeneration || session.value?.id != next.id) {
          return ScreenshotTranslationWindowMessage(
            type: 'ack',
            requestId: message.requestId,
            payload: const {'errorCode': 'stale_update'},
          ).toMap();
        }
        Future<void> showCurrentSession() async {
          if (lifecycle.closing ||
              generation != updateGeneration ||
              session.value?.id != next.id) {
            return;
          }
          if (nativeWindow != null) {
            nativeWindow.show();
          } else {
            await showScreenshotChildWindowUnlessClosing(
              isClosing: () => lifecycle.closing,
              show: () => windowManager.show(inactive: true),
              hide: windowManager.hide,
            );
          }
        }

        if (!firstFramePresented) {
          await activateScreenshotChildAfterFrame(
            firstFrameRasterized: firstFrameRasterized,
            canActivate: () => !lifecycle.closing,
            activate: showCurrentSession,
            onFailure: lifecycle.cleanup,
          );
          firstFramePresented = true;
        } else {
          await showCurrentSession();
        }
        if (lifecycle.closing ||
            generation != updateGeneration ||
            session.value?.id != next.id) {
          if (!lifecycle.closing && nativeWindow == null) {
            await windowManager.hide();
          }
          return ScreenshotTranslationWindowMessage(
            type: 'ack',
            requestId: message.requestId,
            payload: const {'errorCode': 'stale_update'},
          ).toMap();
        }
      }
    }
    return ScreenshotTranslationWindowMessage(
      type: 'ack',
      requestId: message.requestId,
      payload: {'imageReusedForSessionId': ?reusedImageSessionId},
    ).toMap();
  }

  Future<Object?> receive(MethodCall call) {
    if (call.method != _messageMethod) {
      throw MissingPluginException();
    }
    final message = ScreenshotTranslationWindowMessage.fromMap(call.arguments);
    if (message.type != 'sessionUpdated' && message.type != 'probe') {
      return applyMessage(message);
    }

    // Child window visibility calls and host claims are asynchronous. Serialize
    // them so an old hide/show cannot finish after a newer update/connection.
    final queued = sessionUpdateTail.then<Object?>(
      (_) => applyMessage(message),
      onError: (Object _, StackTrace _) => applyMessage(message),
    );
    sessionUpdateTail = queued.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return queued;
  }

  if (lifecycle.closing) return;
  lifecycle.delegate = receive;
  runApp(
    _ResultChildApp(
      session: session,
      channel: channel,
      nativeWindow: nativeWindow,
      lookupHistoryStore: lookupHistoryStore,
    ),
  );
}

Future<ScreenshotDictionaryLookupHistoryStore?>
_screenshotDictionaryLookupHistoryStore() async {
  try {
    final executablePath = Platform.resolvedExecutable;
    final configuredDirectory = Platform.environment['YIXUE_DATA_DIR'];
    final String? dataDirectory;
    if (configuredDirectory?.trim().isNotEmpty == true) {
      dataDirectory = resolveAppDataPath(
        configuredDirectory: configuredDirectory,
        executablePath: executablePath,
      );
    } else if (kDebugMode && Platform.isWindows) {
      dataDirectory = isolatedDebugAppDataPath(
        tempDirectoryPath: Directory.systemTemp.path,
        processId: pid,
      );
    } else {
      final preference = AppDataDirectoryPreferenceStore(
        File(
          resolveAppDataPreferenceFilePath(
            executablePath: executablePath,
            configuredDirectory: Platform.environment['YIXUE_CONFIG_DIR'],
          ),
        ),
      );
      final storedDirectory = await preference.read();
      if (storedDirectory == null) return null;
      dataDirectory = resolveAppDataPath(
        configuredDirectory: configuredDirectory,
        storedDirectory: storedDirectory,
        executablePath: executablePath,
      );
    }
    return FileScreenshotDictionaryLookupHistoryStore(
      File(
        joinAppDataPath(
          dataDirectory,
          'screenshot_translation/dictionary_lookup_history.json',
        ),
      ),
    );
  } catch (error) {
    debugPrint('Screenshot lookup history storage is unavailable: $error');
    return null;
  }
}

Rect _displayPhysicalRect(Display display) {
  final scale = display.scaleFactor?.toDouble() ?? 1;
  final origin = (display.visiblePosition ?? Offset.zero) * scale;
  final size = (display.visibleSize ?? display.size) * scale;
  return origin & size;
}

Future<Offset?> screenshotResultPlacement({
  required Rect selection,
  required Future<Size> Function() readLogicalSize,
  required Future<List<Display>> Function() readDisplays,
  required bool Function() isCurrent,
}) async {
  final logicalSize = await readLogicalSize();
  if (!isCurrent()) return null;
  final displays = await readDisplays();
  if (!isCurrent() || displays.isEmpty) return null;
  final display = displays.reduce((a, b) {
    final areaA = _displayPhysicalRect(a).intersect(selection);
    final areaB = _displayPhysicalRect(b).intersect(selection);
    final scoreA = areaA.isEmpty ? 0 : areaA.width * areaA.height;
    final scoreB = areaB.isEmpty ? 0 : areaB.width * areaB.height;
    return scoreB > scoreA ? b : a;
  });
  return screenshotResultPosition(
    selection,
    _displayPhysicalRect(display),
    logicalSize * (display.scaleFactor?.toDouble() ?? 1),
  );
}

/// Physical coordinates throughout, including negative monitor origins.
Offset screenshotResultPosition(
  Rect selection,
  Rect workArea,
  Size resultSize,
) {
  const gap = 12.0;
  final rightSpace = workArea.right - selection.right;
  final leftSpace = selection.left - workArea.left;
  final x = rightSpace >= resultSize.width + gap || rightSpace >= leftSpace
      ? selection.right + gap
      : selection.left - resultSize.width - gap;
  final maxX = (workArea.right - resultSize.width - gap).clamp(
    workArea.left + gap,
    double.infinity,
  );
  final maxY = (workArea.bottom - resultSize.height - gap).clamp(
    workArea.top + gap,
    double.infinity,
  );
  return Offset(
    x.clamp(workArea.left + gap, maxX).toDouble(),
    selection.top.clamp(workArea.top + gap, maxY).toDouble(),
  );
}

class _ResultChildApp extends StatefulWidget {
  const _ResultChildApp({
    required this.session,
    required this.channel,
    required this.lookupHistoryStore,
    this.nativeWindow,
  });
  final ValueNotifier<ScreenshotTranslationSession?> session;
  final WindowMethodChannel channel;
  final ScreenshotDictionaryLookupHistoryStore? lookupHistoryStore;
  final _InactiveWindowsWindow? nativeWindow;
  @override
  State<_ResultChildApp> createState() => _ResultChildState();
}

class _ResultChildState extends State<_ResultChildApp> with WindowListener {
  bool _topmost = true;
  bool _collapsed = false;
  Size? _expandedSize;
  String? _connectionError;
  int _requests = 0;
  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  Future<void> _send(
    String type, [
    Map<String, Object?> payload = const {},
  ]) async {
    try {
      final request = ScreenshotTranslationWindowMessage(
        type: type,
        requestId: 'result-${++_requests}',
        payload: payload,
      );
      final raw = await widget.channel.invokeMethod<Object?>(
        _messageMethod,
        request.toMap(),
      );
      final ack = ScreenshotTranslationWindowMessage.fromMap(raw);
      if (ack.requestId != request.requestId || ack.type != 'ack') {
        throw const FormatException('Missing acknowledgement');
      }
      if (mounted) setState(() => _connectionError = null);
    } catch (_) {
      if (mounted) setState(() => _connectionError = '与译学主窗口的连接中断，请打开译学后重试。');
    }
  }

  Future<bool> _requestRegionAction(
    String type,
    String? sessionId, {
    bool? pinned,
  }) async {
    if (sessionId == null) return false;
    final payload = <String, Object?>{'sessionId': sessionId};
    if (pinned != null) payload['pinned'] = pinned;
    try {
      final request = ScreenshotTranslationWindowMessage(
        type: type,
        requestId: 'result-${++_requests}',
        payload: payload,
      );
      final raw = await widget.channel.invokeMethod<Object?>(
        _messageMethod,
        request.toMap(),
      );
      final ack = ScreenshotTranslationWindowMessage.fromMap(raw);
      if (ack.requestId != request.requestId || ack.type != 'ack') {
        throw const FormatException('Missing acknowledgement');
      }
      if (ack.payload['errorCode'] case final String code) {
        if (mounted) {
          setState(
            () => _connectionError = switch (code) {
              'region_not_pinned' => '当前没有固定区域，请先固定选区。',
              'stale_region' => '固定区域已更改，请重新固定。',
              'save_failed' => '固定区域设置保存失败，请重试。',
              'stale_session' => '结果已更新，请在当前截图中重试。',
              'window_state_unavailable' => '无法确认译学窗口状态，请稍后重试。',
              'capture_in_progress' => '已有截图正在处理，请稍后再刷新。',
              _ => '区域操作失败，请打开主窗口后重试。',
            },
          );
        }
        return false;
      }
      if (mounted) setState(() => _connectionError = null);
      return true;
    } catch (_) {
      if (mounted) setState(() => _connectionError = '与译学主窗口的连接中断，请打开译学后重试。');
      return false;
    }
  }

  Future<void> _close() async {
    final id = widget.session.value?.id;
    widget.session.value = null;
    await windowManager.hide();
    await _send('resultWindowClosed', {'sessionId': id});
  }

  @override
  void onWindowClose() {
    unawaited(_close());
  }

  Future<ScreenshotWordAddStatus> _addScreenshotWord(
    ScreenshotWordRequest word,
  ) => requestScreenshotWordAdd(
    request: word,
    requestId: 'result-word-${++_requests}',
    send: (payload) =>
        widget.channel.invokeMethod<Object?>(_messageMethod, payload),
  );

  Future<ScreenshotDictionaryLookupResult?> _lookupScreenshotDictionary(
    String word,
  ) async {
    final session = widget.session.value;
    if (session == null) return null;
    return requestScreenshotDictionaryLookup(
      request: ScreenshotDictionaryLookupRequest(
        sessionId: session.id,
        word: word,
        recognizedText: session.recognizedText,
      ),
      requestId: 'result-lookup-${++_requests}',
      send: (payload) =>
          widget.channel.invokeMethod<Object?>(_messageMethod, payload),
    );
  }

  Future<String> _translateSelectedScreenshotWord(
    String word,
    String operationId,
  ) async {
    final current = widget.session.value;
    if (current == null) {
      throw const ScreenshotWordRequestException('stale_session');
    }
    return requestScreenshotWordTranslation(
      request: ScreenshotWordTranslationRequest(
        sessionId: current.id,
        word: word,
        recognizedText: current.recognizedText,
      ),
      requestId: operationId,
      ackTimeout: screenshotWordTranslationAckTimeout,
      send: (payload) =>
          widget.channel.invokeMethod<Object?>(_messageMethod, payload),
    );
  }

  Future<bool> _cancelSelectedScreenshotWordTranslation(String operationId) =>
      cancelScreenshotWordTranslation(
        operationId: operationId,
        requestId: 'result-word-cancel-${++_requests}',
        ackTimeout: screenshotWordTranslationCancellationAckTimeout,
        send: (payload) =>
            widget.channel.invokeMethod<Object?>(_messageMethod, payload),
      );

  Future<void> _collapse() async {
    if (_collapsed) {
      await windowManager.setMinimumSize(const Size(420, 300));
      await windowManager.setSize(_expandedSize ?? const Size(560, 400));
      await windowManager.setResizable(true);
    } else {
      _expandedSize = await windowManager.getSize();
      await windowManager.setMinimumSize(const Size(260, 48));
      await windowManager.setSize(const Size(300, 48));
      await windowManager.setResizable(false);
    }
    if (mounted) setState(() => _collapsed = !_collapsed);
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.light(),
    home: ValueListenableBuilder<ScreenshotTranslationSession?>(
      valueListenable: widget.session,
      builder: (context, session, _) => Column(
        children: [
          if (_connectionError != null && !_collapsed)
            Material(
              color: const Color(0xFFFFE8E8),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  _connectionError!,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ),
          Expanded(
            child: ScreenshotTranslationResultWindow(
              session: session,
              onAddScreenshotWord: _addScreenshotWord,
              onLookupDictionary: _lookupScreenshotDictionary,
              onTranslateSelectedWord: _translateSelectedScreenshotWord,
              onCancelSelectedWordTranslation:
                  _cancelSelectedScreenshotWordTranslation,
              lookupHistoryStore: widget.lookupHistoryStore,
              onCapture: () => unawaited(_send('captureRequested')),
              onSetPinnedRegion: (pinned) => _requestRegionAction(
                'togglePinnedRegionRequested',
                session?.id,
                pinned: pinned,
              ),
              onRefreshPinnedRegion: () => _requestRegionAction(
                'refreshPinnedRegionRequested',
                session?.id,
              ),
              onRetranslate: (source) => unawaited(
                _send('retranslateRequested', {
                  'sessionId': session?.id,
                  'source': source,
                }),
              ),
              onReverseDirection: (source) => unawaited(
                _send('retranslateRequested', {
                  'sessionId': session?.id,
                  'source': source,
                  'reverseDirection': true,
                }),
              ),
              onHistory: () => unawaited(_send('openHistory')),
              onOpenModels: () => unawaited(_send('openModels')),
              onClose: () => unawaited(_close()),
              onDrag: () => unawaited(windowManager.startDragging()),
              topmost: _topmost,
              collapsed: _collapsed,
              onToggleCollapsed: () => unawaited(_collapse()),
              onToggleTopmost: () async {
                try {
                  if (widget.nativeWindow case final native?) {
                    native.topmost(!_topmost);
                  } else {
                    await windowManager.setAlwaysOnTop(!_topmost);
                  }
                  if (mounted) setState(() => _topmost = !_topmost);
                } catch (_) {
                  if (mounted) {
                    setState(() => _connectionError = '置顶切换失败，请从主界面重新打开结果。');
                  }
                }
              },
            ),
          ),
        ],
      ),
    ),
  );
}

typedef _FindWindowNative = IntPtr Function(Pointer<Utf16>, Pointer<Utf16>);
typedef _FindWindowDart = int Function(Pointer<Utf16>, Pointer<Utf16>);
typedef _ShowWindowNative = Int32 Function(IntPtr, Int32);
typedef _ShowWindowDart = int Function(int, int);
typedef _IsWindowVisibleNative = Int32 Function(IntPtr);
typedef _IsWindowVisibleDart = int Function(int);
typedef _SetWindowPosNative = Int32 Function(
  IntPtr,
  IntPtr,
  Int32,
  Int32,
  Int32,
  Int32,
  Uint32,
);
typedef _SetWindowPosDart = int Function(int, int, int, int, int, int, int);

final class _WindowRect extends Struct {
  @Int32()
  external int left;
  @Int32()
  external int top;
  @Int32()
  external int right;
  @Int32()
  external int bottom;
}

final class _InactiveWindowsWindow {
  _InactiveWindowsWindow(this.handle);
  final int handle;
  static final _user32 = DynamicLibrary.open('user32.dll');
  static final _find = _user32
      .lookupFunction<_FindWindowNative, _FindWindowDart>('FindWindowW');
  static final _show = _user32
      .lookupFunction<_ShowWindowNative, _ShowWindowDart>('ShowWindow');
  static final _visible = _user32
      .lookupFunction<_IsWindowVisibleNative, _IsWindowVisibleDart>(
        'IsWindowVisible',
      );
  static final _position = _user32
      .lookupFunction<_SetWindowPosNative, _SetWindowPosDart>('SetWindowPos');
  static final _rect = _user32
      .lookupFunction<
        Int32 Function(IntPtr, Pointer<_WindowRect>),
        int Function(int, Pointer<_WindowRect>)
      >('GetWindowRect');

  Offset readPosition() {
    final rect = calloc<_WindowRect>();
    try {
      if (_rect(handle, rect) == 0) {
        throw StateError('Screenshot window bounds unavailable');
      }
      return Offset(rect.ref.left.toDouble(), rect.ref.top.toDouble());
    } finally {
      calloc.free(rect);
    }
  }

  void place(Offset origin, Size physicalSize) {
    if (_position(
          handle,
          0,
          origin.dx.round(),
          origin.dy.round(),
          physicalSize.width.round(),
          physicalSize.height.round(),
          0x0014,
        ) ==
        0) {
      throw StateError(
        'Screenshot window could not be placed without activation',
      );
    }
    // One SetWindowPos updates position and size without an intermediate
    // pointer hit-test against stale bounds. SWP_NOZORDER | SWP_NOACTIVATE.
  }

  static Future<_InactiveWindowsWindow> find(String id) async {
    final title =
        'yixue-screenshot-result-$id-${DateTime.now().microsecondsSinceEpoch}';
    final previousTitle = await windowManager.getTitle();
    await windowManager.setTitle(title);
    final nativeTitle = title.toNativeUtf16();
    try {
      final handle = _find(nullptr, nativeTitle);
      if (handle == 0) throw StateError('Screenshot result HWND unavailable');
      return _InactiveWindowsWindow(handle);
    } finally {
      calloc.free(nativeTitle);
      await windowManager.setTitle(previousTitle);
    }
  }

  void show() {
    _show(handle, 4); // Returns previous visibility, not success/failure.
    if (_visible(handle) == 0) {
      throw StateError(
        'Screenshot result HWND could not be shown without activation',
      );
    }
  } // SW_SHOWNOACTIVATE

  void position(Offset offset) {
    if (_position(
          handle,
          0,
          offset.dx.round(),
          offset.dy.round(),
          0,
          0,
          0x0015,
        ) ==
        0) {
      throw StateError(
        'Screenshot result window could not be positioned without activation',
      );
    }
    // SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE
  }

  void topmost(bool value) {
    if (_position(handle, value ? -1 : -2, 0, 0, 0, 0, 0x0013) == 0) {
      throw StateError(
        'Screenshot result HWND could not change topmost without activation',
      );
    }
    // HWND_TOPMOST / HWND_NOTOPMOST, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE.
  }
}
