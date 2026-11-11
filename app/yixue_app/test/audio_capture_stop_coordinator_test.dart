import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/features/simultaneous_interpretation/audio_capture_stop_coordinator.dart';

void main() {
  test('stops attempted audio sources in reverse order', () async {
    final stopped = <String>[];

    final result = await stopCaptureSources<String>(
      ['system', 'microphone'],
      (source) async {
        stopped.add(source);
      },
    );

    expect(stopped, ['microphone', 'system']);
    expect(result.stoppedSources, ['microphone', 'system']);
    expect(result.failedSources, isEmpty);
    expect(result.allStopped, isTrue);
  });

  test('retains only sources whose stop could not be confirmed', () async {
    final stopped = <String>[];

    final result = await stopCaptureSources<String>(
      ['system', 'microphone', 'loopback'],
      (source) async {
        stopped.add(source);
        if (source == 'microphone') throw StateError('still capturing');
      },
    );

    expect(stopped, ['loopback', 'microphone', 'system']);
    expect(result.stoppedSources, ['loopback', 'system']);
    expect(result.failedSources, ['microphone']);
    expect(result.allStopped, isFalse);
  });
}
