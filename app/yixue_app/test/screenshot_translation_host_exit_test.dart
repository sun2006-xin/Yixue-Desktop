import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/features/screenshot_translation/screenshot_translation_host_exit.dart';

void main() {
  test('explicit screenshot quit uses the main app exit controller', () async {
    final events = <String>[];
    final exit = resolveScreenshotHostExit(
      requestHostClose: () async => events.add('app-exit-controller'),
      closeWindow: () async => events.add('direct-window-close'),
    );

    await exit();

    expect(events, ['app-exit-controller']);
  });

  test('standalone screenshot preview can still close its own window', () async {
    final events = <String>[];
    final exit = resolveScreenshotHostExit(
      requestHostClose: null,
      closeWindow: () async => events.add('direct-window-close'),
    );

    await exit();

    expect(events, ['direct-window-close']);
  });
}
