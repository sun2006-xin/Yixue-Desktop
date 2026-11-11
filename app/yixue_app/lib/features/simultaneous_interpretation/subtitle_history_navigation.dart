import 'package:flutter/foundation.dart';

import 'subtitle_window_host.dart';

/// Hides the independent, always-on-top caption window before opening history.
///
/// History is opened only after the native topmost window acknowledges hide.
/// Opening behind an unresponsive child leaves the user with an apparently
/// frozen or gray full-screen page, so a failed hide must stop navigation.
Future<Object?> hideSubtitleWindowBeforeHistoryNavigation({
  required SubtitleWindowController subtitleWindow,
  required Future<void> Function() openHistory,
  VoidCallback? onHidden,
  void Function(Object error)? onHideFailure,
}) async {
  Object? failure;
  try {
    await subtitleWindow.hide();
  } on Object catch (error) {
    failure = error;
  }
  if (failure != null) {
    onHideFailure?.call(failure);
    return failure;
  }
  onHidden?.call();
  await openHistory();
  return null;
}
