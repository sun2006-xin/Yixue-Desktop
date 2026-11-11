import 'package:flutter/services.dart';
import 'package:yixue_app/core/screenshot_translation_preferences.dart';
import 'package:yixue_app/core/screenshot_translation_window_protocol.dart';
import 'package:yixue_app/features/screenshot_translation/screenshot_translation_runtime.dart';

/// Main-engine adapter for the Windows runner's lightweight native orb HWND.
/// The orb emits only commands; capture, settings, history and exit remain
/// owned by ScreenshotTranslationDesktopController in the main Dart engine.
final class WindowsScreenshotNativeOrb
    implements ScreenshotOrbHandle, ScreenshotOrbCaptureVisibility {
  WindowsScreenshotNativeOrb({required this.onMessage, MethodChannel? channel})
    : _channel = channel ?? _nativeOrbChannel;

  static const MethodChannel _nativeOrbChannel = MethodChannel(
    'yixue/screenshot_translation/native_orb',
  );

  final Future<void> Function(ScreenshotTranslationWindowMessage message)
  onMessage;
  final MethodChannel _channel;
  bool _handlerRegistered = false;

  @override
  Future<void> open(ScreenshotOrbPosition? position) async {
    if (!_handlerRegistered) {
      _channel.setMethodCallHandler(_handleNativeCall);
      _handlerRegistered = true;
    }
    await _channel.invokeMethod<bool>(
      'open',
      position == null ? null : {'x': position.x, 'y': position.y},
    );
  }

  @override
  Future<void> close() async {
    await _channel.invokeMethod<bool>('close');
    if (_handlerRegistered) {
      _channel.setMethodCallHandler(null);
      _handlerRegistered = false;
    }
  }

  @override
  Future<void> hideForCapture() async {
    await _channel.invokeMethod<bool>('hideForCapture');
  }

  @override
  Future<void> restoreAfterCapture() async {
    await _channel.invokeMethod<bool>('restoreAfterCapture');
  }

  Future<Object?> _handleNativeCall(MethodCall call) async {
    if (call.method != 'onCommand') {
      throw MissingPluginException(
        'Unknown native screenshot orb callback: ${call.method}',
      );
    }
    final message = ScreenshotTranslationWindowMessage.fromMap(call.arguments);
    await onMessage(message);
    return ScreenshotTranslationWindowMessage(
      type: 'ack',
      requestId: message.requestId,
      payload: const {},
    ).toMap();
  }
}
