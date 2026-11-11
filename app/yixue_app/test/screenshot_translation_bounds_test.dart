import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_screenshot/screenshot.dart';
import 'package:just_screenshot/screenshot_method_channel.dart';
import 'package:yixue_app/core/screenshot_translation_capture_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final bytes = Uint8List.fromList([137, 80, 78, 71]);
  final nativeMap = <Object?, Object?>{
    'left': -1680,
    'top': -240,
    'width': 321,
    'height': 123,
    'bytes': bytes,
  };

  test('physical bounds preserve negative origins and exclusive edges', () {
    const bounds = ScreenshotBounds(
      left: -1680,
      top: -240,
      width: 321,
      height: 123,
    );
    expect(bounds.right, -1359);
    expect(bounds.bottom, -117);
    expect(
      bounds,
      const ScreenshotBounds(left: -1680, top: -240, width: 321, height: 123),
    );
    expect(
      bounds.hashCode,
      const ScreenshotBounds(
        left: -1680,
        top: -240,
        width: 321,
        height: 123,
      ).hashCode,
    );
  });

  test('native data round trips physical coordinates and includes them in equality', () {
    final capture = CapturedData.fromMap(nativeMap);
    expect(
      capture.bounds,
      const ScreenshotBounds(left: -1680, top: -240, width: 321, height: 123),
    );
    expect(capture.toMap(), nativeMap);
    final moved = CapturedData.fromMap({...nativeMap, 'left': 0});
    expect(capture, isNot(moved));
  });

  test(
    'invalid or missing physical bounds are rejected instead of invented',
    () {
      for (final dimension in ['width', 'height']) {
        expect(
          () => CapturedData.fromMap({...nativeMap, dimension: 0}),
          throwsArgumentError,
        );
      }
      expect(
        () => CapturedData.fromMap({...nativeMap}..remove('left')),
        throwsA(isA<TypeError>()),
      );
      expect(
        () => CapturedData.fromMap({...nativeMap, 'bytes': Uint8List(0)}),
        throwsArgumentError,
      );
    },
  );

  test('application capture retains the same physical bounds', () {
    final data = CapturedData.fromMap(nativeMap);
    final capture = ScreenshotTranslationCapture(
      imageBytes: data.bytes,
      bounds: data.bounds,
      recognizedText: 'Example',
    );
    expect(capture.bounds, data.bounds);
    expect(capture.width, 321);
    expect(capture.height, 123);
  });

  test('channel preserves physical map, cancellation, and actual failure distinctly', () async {
    final platform = MethodChannelScreenshot();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    addTearDown(
      () => messenger.setMockMethodCallHandler(platform.methodChannel, null),
    );
    messenger.setMockMethodCallHandler(
      platform.methodChannel,
      (_) async => nativeMap,
    );
    expect(
      (await platform.capture(mode: ScreenshotMode.region))!.bounds.left,
      -1680,
    );
    messenger.setMockMethodCallHandler(
      platform.methodChannel,
      (_) async => null,
    );
    expect(await platform.capture(mode: ScreenshotMode.region), isNull);
    messenger.setMockMethodCallHandler(
      platform.methodChannel,
      (_) async => throw PlatformException(
        code: 'internal_error',
        message: 'Desktop capture failed',
      ),
    );
    await expectLater(
      platform.capture(mode: ScreenshotMode.region),
      throwsA(isA<ScreenshotException>()),
    );
  });
}
