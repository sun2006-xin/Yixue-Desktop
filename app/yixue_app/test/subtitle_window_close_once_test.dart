import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/features/simultaneous_interpretation/subtitle_window_host.dart';

void main() {
  group('SubtitleWindowCloseOnce', () {
    test(
      'coalesces concurrent calls and waits for the same close to finish',
      () async {
        final closeOnce = SubtitleWindowCloseOnce();
        final closeStarted = Completer<void>();
        final allowCloseToFinish = Completer<void>();
        var closeCount = 0;

        Future<void> close() async {
          closeCount += 1;
          if (!closeStarted.isCompleted) closeStarted.complete();
          await allowCloseToFinish.future;
        }

        final completions = List<bool>.filled(3, false);
        final calls = <Future<void>>[
          closeOnce.close(close),
          closeOnce.close(close),
          closeOnce.close(close),
        ];
        for (var index = 0; index < calls.length; index += 1) {
          unawaited(calls[index].then((_) => completions[index] = true));
        }

        await closeStarted.future;
        await Future<void>.delayed(Duration.zero);

        expect(closeCount, 1);
        expect(completions, everyElement(isFalse));

        allowCloseToFinish.complete();
        await Future.wait(calls);

        expect(closeCount, 1);
        expect(completions, everyElement(isTrue));
      },
    );

    test('does not retry the close callback after it throws', () async {
      final closeOnce = SubtitleWindowCloseOnce();
      final failure = StateError('subtitle child close failed');
      var closeCount = 0;

      Future<void> close() async {
        closeCount += 1;
        throw failure;
      }

      await expectLater(closeOnce.close(close), throwsA(same(failure)));
      await expectLater(closeOnce.close(close), throwsA(same(failure)));

      expect(closeCount, 1);
    });
  });
}
