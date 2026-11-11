import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/core/retryable_single_flight_operation.dart';

void main() {
  test('concurrent cleanup calls share one in-flight attempt', () async {
    final operation = RetryableSingleFlightOperation();
    final started = Completer<void>();
    final finish = Completer<void>();
    var calls = 0;

    final first = operation.run(() async {
      calls++;
      started.complete();
      await finish.future;
    });
    await started.future;
    final second = operation.run(() async {
      calls++;
    });

    expect(identical(first, second), isTrue);
    expect(calls, 1);
    finish.complete();
    await Future.wait([first, second]);
    expect(calls, 1);
  });

  test('failed cleanup can be retried, then success remains memoized', () async {
    final operation = RetryableSingleFlightOperation();
    var calls = 0;

    await expectLater(
      operation.run(() async {
        calls++;
        throw StateError('temporary cleanup failure');
      }),
      throwsA(isA<StateError>()),
    );

    await operation.run(() async {
      calls++;
    });
    await operation.run(() async {
      calls++;
    });

    expect(calls, 2);
  });
}
