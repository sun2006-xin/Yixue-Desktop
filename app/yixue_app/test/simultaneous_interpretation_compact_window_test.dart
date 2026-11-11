import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/features/simultaneous_interpretation/simultaneous_interpretation_page.dart';

void main() {
  group('compact subtitle window transition', () {
    const normalBounds = Rect.fromLTWH(40, 70, 1200, 800);
    const normalMinimumSize = Size(960, 620);
    const compactMinimumSize = Size(520, 220);
    const compactSize = Size(700, 320);

    for (final failingOperation in <String>[
      'unmaximize',
      'setMinimumSize',
      'setResizable',
      'setAlwaysOnTop',
      'setBounds',
    ]) {
      test(
        '$failingOperation failure restores the previous window state',
        () async {
          final actions = _FakeCompactSubtitleWindowActions(
            failAfterMutationOn: failingOperation,
            initiallyMaximized: failingOperation == 'unmaximize',
          );
          CompactSubtitleWindowRestoreState? restoreState;
          var compactLayout = false;

          await expectLater(
            enterCompactSubtitleWindow(
              actions: actions,
              normalMinimumSize: normalMinimumSize,
              compactMinimumSize: compactMinimumSize,
              compactSize: compactSize,
              canContinue: () => true,
              waitForLayout: () async {},
              onRestoreStateChanged: (value) => restoreState = value,
              onCompactModeChanged: (value) => compactLayout = value,
            ),
            throwsA(
              isA<CompactSubtitleWindowTransitionException>().having(
                (error) => error.restored,
                'restored',
                isTrue,
              ),
            ),
          );

          expect(actions.bounds, normalBounds);
          expect(actions.minimumSize, normalMinimumSize);
          expect(actions.resizable, isFalse);
          expect(actions.alwaysOnTop, isFalse);
          expect(actions.maximized, failingOperation == 'unmaximize');
          expect(restoreState, isNull);
          expect(compactLayout, isFalse);
          if (failingOperation == 'unmaximize') {
            expect(actions.calls, contains('maximize'));
          } else {
            expect(actions.calls, contains('setBounds:restore'));
          }
          expect(actions.calls, contains('setAlwaysOnTop:false'));
        },
      );
    }

    test(
      'exit invalidation during the frame wait prevents delayed resize',
      () async {
        final actions = _FakeCompactSubtitleWindowActions();
        var generation = 1;
        CompactSubtitleWindowRestoreState? restoreState;
        var compactLayout = false;

        final result = await enterCompactSubtitleWindow(
          actions: actions,
          normalMinimumSize: normalMinimumSize,
          compactMinimumSize: compactMinimumSize,
          compactSize: compactSize,
          canContinue: () => generation == 1,
          waitForLayout: () async {
            // Simulates app exit or cancellation winning while the native
            // compact-window transition is waiting for Flutter's next frame.
            generation++;
          },
          onRestoreStateChanged: (value) => restoreState = value,
          onCompactModeChanged: (value) => compactLayout = value,
        );

        expect(result, isNull);
        expect(actions.calls, isNot(contains('setBounds:compact')));
        expect(actions.bounds, normalBounds);
        expect(actions.minimumSize, normalMinimumSize);
        expect(actions.resizable, isFalse);
        expect(actions.alwaysOnTop, isFalse);
        expect(actions.maximized, isFalse);
        expect(restoreState, isNull);
        expect(compactLayout, isFalse);
      },
    );

    test(
      'restore attempts every operation after one restore call throws',
      () async {
        final actions = _FakeCompactSubtitleWindowActions()
          ..failBeforeMutationOn = 'setResizable';
        const restoreState = CompactSubtitleWindowRestoreState(
          bounds: normalBounds,
          minimumSize: normalMinimumSize,
          isResizable: false,
          isAlwaysOnTop: false,
          wasMaximized: true,
        );

        await expectLater(
          restoreCompactSubtitleWindow(actions: actions, state: restoreState),
          throwsA(isA<StateError>()),
        );

        expect(actions.calls, contains('maximize'));
        expect(actions.calls, contains('setAlwaysOnTop:false'));
      },
    );

    test(
      'stale resize callbacks do not submit after exit or cancellation',
      () async {
        final appliedSizes = <Size>[];
        const size = Size(900, 500);

        final appliedAfterExit = await applyCompactSubtitleResizeIfCurrent(
          generation: 4,
          currentGeneration: 4,
          canResize: false,
          size: size,
          apply: (value) async => appliedSizes.add(value),
        );
        final appliedAfterCancellation =
            await applyCompactSubtitleResizeIfCurrent(
              generation: 4,
              currentGeneration: 5,
              canResize: true,
              size: size,
              apply: (value) async => appliedSizes.add(value),
            );

        expect(appliedAfterExit, isFalse);
        expect(appliedAfterCancellation, isFalse);
        expect(appliedSizes, isEmpty);
      },
    );
  });
}

final class _FakeCompactSubtitleWindowActions
    implements CompactSubtitleWindowActions {
  _FakeCompactSubtitleWindowActions({
    this.failAfterMutationOn,
    bool initiallyMaximized = false,
  }) : maximized = initiallyMaximized;

  final List<String> calls = [];
  String? failAfterMutationOn;
  String? failBeforeMutationOn;
  Rect bounds = const Rect.fromLTWH(40, 70, 1200, 800);
  Size minimumSize = const Size(960, 620);
  bool resizable = false;
  bool alwaysOnTop = false;
  bool maximized;

  void _record(String call) {
    calls.add(call);
    if (failBeforeMutationOn == call) {
      failBeforeMutationOn = null;
      throw StateError('injected $call failure');
    }
  }

  void _failAfterMutation(String operation) {
    if (failAfterMutationOn == operation) {
      failAfterMutationOn = null;
      throw StateError('injected $operation failure');
    }
  }

  @override
  Future<Rect> getBounds() async {
    calls.add('getBounds');
    return bounds;
  }

  @override
  Future<bool> isAlwaysOnTop() async {
    calls.add('isAlwaysOnTop');
    return alwaysOnTop;
  }

  @override
  Future<bool> isMaximized() async {
    calls.add('isMaximized');
    return maximized;
  }

  @override
  Future<bool> isResizable() async {
    calls.add('isResizable');
    return resizable;
  }

  @override
  Future<void> maximize() async {
    _record('maximize');
    maximized = true;
  }

  @override
  Future<void> setAlwaysOnTop(bool value) async {
    _record('setAlwaysOnTop:$value');
    alwaysOnTop = value;
    _failAfterMutation('setAlwaysOnTop');
  }

  @override
  Future<void> setBounds(Rect? value, {Offset? position, Size? size}) async {
    if (value != null) {
      calls.add('setBounds:restore');
      bounds = value;
      _failAfterMutation('setBounds:restore');
      return;
    }
    calls.add('setBounds:compact');
    bounds = Rect.fromLTWH(
      position?.dx ?? bounds.left,
      position?.dy ?? bounds.top,
      size?.width ?? bounds.width,
      size?.height ?? bounds.height,
    );
    _failAfterMutation('setBounds');
  }

  @override
  Future<void> setMinimumSize(Size value) async {
    _record('setMinimumSize');
    minimumSize = value;
    _failAfterMutation('setMinimumSize');
  }

  @override
  Future<void> setResizable(bool value) async {
    _record('setResizable');
    resizable = value;
    _failAfterMutation('setResizable');
  }

  @override
  Future<void> setSize(Size value) async {
    calls.add('setSize');
    bounds = Rect.fromLTWH(bounds.left, bounds.top, value.width, value.height);
  }

  @override
  Future<void> startDragging() async {
    calls.add('startDragging');
  }

  @override
  Future<void> unmaximize() async {
    _record('unmaximize');
    maximized = false;
    _failAfterMutation('unmaximize');
  }
}
