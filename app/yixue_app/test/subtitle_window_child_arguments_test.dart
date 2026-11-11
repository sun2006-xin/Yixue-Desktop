import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/features/simultaneous_interpretation/subtitle_window_host.dart';
import 'package:yixue_app/features/simultaneous_interpretation/subtitle_window_runtime.dart';

void main() {
  group('SubtitleWindowChildArguments', () {
    test('does not route regular app arguments to the subtitle process', () {
      expect(SubtitleWindowChildArguments.parse(const <String>[]), isNull);
      expect(
        SubtitleWindowChildArguments.parse(const <String>['--verbose']),
        isNull,
      );
    });

    test('parses the private local IPC endpoint and token', () {
      final parsed = SubtitleWindowChildArguments.parse(const <String>[
        subtitleWindowChildArgument,
        '${subtitleWindowPortPrefix}43127',
        '${subtitleWindowTokenPrefix}one-time-token',
      ]);

      expect(parsed, isNotNull);
      expect(parsed!.port, 43127);
      expect(parsed.token, 'one-time-token');
    });

    test('rejects incomplete or out-of-range child arguments', () {
      expect(
        () => SubtitleWindowChildArguments.parse(const <String>[
          subtitleWindowChildArgument,
        ]),
        throwsFormatException,
      );
      expect(
        () => SubtitleWindowChildArguments.parse(const <String>[
          subtitleWindowChildArgument,
          '${subtitleWindowPortPrefix}65536',
          '${subtitleWindowTokenPrefix}token',
        ]),
        throwsFormatException,
      );
    });
  });
}
