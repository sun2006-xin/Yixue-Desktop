import 'dart:async';

import 'package:flutter/foundation.dart';

/// Process-wide lease for history media that owns native playback resources.
///
/// The lease survives history-page navigation and is released only after the
/// modal route is gone, its dialog has reported teardown, and any native close
/// future has settled.
final class SubtitleMediaPlaybackCoordinator extends ChangeNotifier {
  SubtitleMediaPlaybackCoordinator._();

  @visibleForTesting
  SubtitleMediaPlaybackCoordinator.forTesting();

  static final instance = SubtitleMediaPlaybackCoordinator._();

  SubtitleMediaPlaybackLease? _activeLease;
  SubtitleMediaMutationLease? _activeMutationLease;

  bool get isBusy => _activeLease != null || _activeMutationLease != null;
  bool get isPlaybackBusy => _activeLease != null;
  bool get isMutationBusy => _activeMutationLease != null;
  String? get activeKey => _activeLease?.key;
  String? get activeMutationKey => _activeMutationLease?.key;

  SubtitleMediaPlaybackLease? tryAcquire(
    String key, {
    VoidCallback? onReleased,
  }) {
    if (isBusy) return null;
    late final SubtitleMediaPlaybackLease lease;
    lease = SubtitleMediaPlaybackLease._(key, () {
      if (identical(_activeLease, lease)) {
        _activeLease = null;
        notifyListeners();
      }
      onReleased?.call();
    }, notifyListeners);
    _activeLease = lease;
    notifyListeners();
    return lease;
  }

  SubtitleMediaMutationLease? tryAcquireMutation(String key) {
    if (isBusy) return null;
    late final SubtitleMediaMutationLease lease;
    lease = SubtitleMediaMutationLease._(key, () {
      if (identical(_activeMutationLease, lease)) {
        _activeMutationLease = null;
        notifyListeners();
      }
    });
    _activeMutationLease = lease;
    notifyListeners();
    return lease;
  }
}

/// Exclusive reservation for history operations that can change media files.
///
/// The history UI intentionally serializes those operations with playback so
/// another history route cannot open a file while it is being removed or
/// recovered.
final class SubtitleMediaMutationLease {
  SubtitleMediaMutationLease._(this.key, this._releaseFromCoordinator);

  final String key;
  final VoidCallback _releaseFromCoordinator;
  var _released = false;

  bool get isReleased => _released;

  void release() {
    if (_released) return;
    _released = true;
    _releaseFromCoordinator();
  }
}

final class SubtitleMediaPlaybackLease {
  SubtitleMediaPlaybackLease._(this.key, this._onReleased, this._onChanged);

  final String key;
  final VoidCallback _onReleased;
  final VoidCallback _onChanged;
  final Completer<void> _releasedCompleter = Completer<void>();

  Future<void>? _pendingNativeClose;
  var _dialogDisposed = false;
  var _routeClosed = false;
  var _released = false;

  bool get isReleased => _released;

  /// Completes after the modal route, dialog teardown, and native close settle.
  Future<void> get whenReleased => _releasedCompleter.future;

  /// Called by the dialog from [State.dispose]. A non-null future must be the
  /// original native close/dispose operation, not a timeout wrapper.
  void reportDialogDisposed(Future<void>? pendingNativeClose) {
    if (_dialogDisposed || _released) return;
    _dialogDisposed = true;
    if (pendingNativeClose != null) _trackNativeClose(pendingNativeClose);
    _releaseIfSettled();
  }

  /// Called when the modal route has finished closing.
  void reportRouteClosed() {
    if (_routeClosed || _released) return;
    _routeClosed = true;
    _releaseIfSettled();
  }

  void _trackNativeClose(Future<void> close) {
    if (identical(_pendingNativeClose, close)) return;
    _pendingNativeClose = close;
    _onChanged();
    unawaited(
      close.then<void>(
        (_) => _nativeCloseSettled(close),
        onError: (Object error, StackTrace stackTrace) {
          _nativeCloseSettled(close);
        },
      ),
    );
  }

  void _nativeCloseSettled(Future<void> close) {
    if (!identical(_pendingNativeClose, close) || _released) return;
    _pendingNativeClose = null;
    _onChanged();
    _releaseIfSettled();
  }

  void _releaseIfSettled() {
    if (_released ||
        !_dialogDisposed ||
        !_routeClosed ||
        _pendingNativeClose != null) {
      return;
    }
    _released = true;
    try {
      _onReleased();
    } finally {
      _releasedCompleter.complete();
    }
  }
}
