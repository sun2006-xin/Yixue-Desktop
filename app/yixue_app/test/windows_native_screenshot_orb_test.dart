import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/core/screenshot_translation_preferences.dart';
import 'package:yixue_app/core/screenshot_translation_window_protocol.dart';
import 'package:yixue_app/features/screenshot_translation/windows_native_screenshot_orb.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('test/yixue/native_screenshot_orb');
  const codec = StandardMethodCodec();

  test(
    'opens and closes the native HWND with physical saved coordinates',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return true;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      final orb = WindowsScreenshotNativeOrb(
        channel: channel,
        onMessage: (_) async {},
      );
      await orb.open(const ScreenshotOrbPosition(-1280, 420));
      await orb.hideForCapture();
      await orb.restoreAfterCapture();
      await orb.close();

      expect(calls.map((call) => call.method), [
        'open',
        'hideForCapture',
        'restoreAfterCapture',
        'close',
      ]);
      expect(calls.first.arguments, {'x': -1280.0, 'y': 420.0});
    },
  );

  test(
    'routes native orb commands to the main desktop controller callback',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (_) async => true);
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final messages = <ScreenshotTranslationWindowMessage>[];
      final orb = WindowsScreenshotNativeOrb(
        channel: channel,
        onMessage: (message) async => messages.add(message),
      );
      await orb.open(null);
      addTearDown(() => orb.close());

      final request = ScreenshotTranslationWindowMessage(
        type: 'captureRequested',
        requestId: 'native-42',
        payload: const {},
      );
      final response = await messenger.handlePlatformMessage(
        channel.name,
        codec.encodeMethodCall(MethodCall('onCommand', request.toMap())),
        null,
      );

      expect(messages, hasLength(1));
      expect(messages.single.type, 'captureRequested');
      expect(messages.single.requestId, 'native-42');
      expect(messages.single.payload, isEmpty);
      expect(
        codec.decodeEnvelope(response!),
        ScreenshotTranslationWindowMessage(
          type: 'ack',
          requestId: 'native-42',
          payload: const {},
        ).toMap(),
      );
      await orb.close();
    },
  );
}
