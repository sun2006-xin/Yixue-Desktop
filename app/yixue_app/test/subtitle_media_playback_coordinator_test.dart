import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/features/simultaneous_interpretation/subtitle_media_playback_coordinator.dart';

void main() {
  test(
    'holds history media until route, dialog, and native close settle',
    () async {
      final coordinator = SubtitleMediaPlaybackCoordinator.forTesting();
      var releaseCount = 0;
      final lease = coordinator.tryAcquire(
        'audio:session:recording:file.wav',
        onReleased: () => releaseCount++,
      )!;
      final nativeClose = Completer<void>();

      lease.reportRouteClosed();
      lease.reportDialogDisposed(nativeClose.future);

      expect(coordinator.isBusy, isTrue);
      expect(coordinator.activeKey, 'audio:session:recording:file.wav');
      expect(coordinator.tryAcquire('video:other.mp4'), isNull);
      expect(releaseCount, 0);

      nativeClose.complete();
      await Future<void>.delayed(Duration.zero);

      expect(coordinator.isBusy, isFalse);
      expect(coordinator.activeKey, isNull);
      expect(releaseCount, 1);
      expect(coordinator.tryAcquire('video:other.mp4'), isNotNull);
    },
  );

  test(
    'exposes release only after dialog, route, and native close settle',
    () async {
      final coordinator = SubtitleMediaPlaybackCoordinator.forTesting();
      final lease = coordinator.tryAcquire('video:handoff.mp4')!;
      final nativeClose = Completer<void>();
      var released = false;
      final releaseFuture = lease.whenReleased.then((_) => released = true);

      lease.reportDialogDisposed(nativeClose.future);
      lease.reportRouteClosed();
      await Future<void>.delayed(Duration.zero);

      expect(coordinator.isBusy, isTrue);
      expect(released, isFalse);

      nativeClose.complete();
      await releaseFuture;

      expect(coordinator.isBusy, isFalse);
      expect(lease.isReleased, isTrue);
      expect(released, isTrue);
    },
  );

  test('releases an external-player dialog after the route closes', () {
    final coordinator = SubtitleMediaPlaybackCoordinator.forTesting();
    final lease = coordinator.tryAcquire('video:external.mp4')!;

    lease.reportDialogDisposed(null);
    expect(coordinator.isBusy, isTrue);

    lease.reportRouteClosed();
    expect(coordinator.isBusy, isFalse);
  });

  test('releases after a native close future settles with an error', () async {
    final coordinator = SubtitleMediaPlaybackCoordinator.forTesting();
    final lease = coordinator.tryAcquire('audio:failed-close.wav')!;
    final nativeClose = Completer<void>();

    lease.reportDialogDisposed(nativeClose.future);
    lease.reportRouteClosed();
    nativeClose.completeError(StateError('native dispose failed'));
    await Future<void>.delayed(Duration.zero);

    expect(coordinator.isBusy, isFalse);
  });

  test('blocks playback while a history mutation owns the media store', () {
    final coordinator = SubtitleMediaPlaybackCoordinator.forTesting();
    final mutation = coordinator.tryAcquireMutation('delete-session:session-1');

    expect(mutation, isNotNull);
    expect(coordinator.isBusy, isTrue);
    expect(
      coordinator.tryAcquire('audio:session-1:recording-1:file.wav'),
      isNull,
    );

    mutation!.release();

    expect(coordinator.isBusy, isFalse);
    expect(
      coordinator.tryAcquire('audio:session-1:recording-1:file.wav'),
      isNotNull,
    );
  });

  test('blocks history mutation while a player owns the media store', () {
    final coordinator = SubtitleMediaPlaybackCoordinator.forTesting();
    final player = coordinator.tryAcquire(
      'audio:session-1:recording-1:file.wav',
    )!;

    expect(coordinator.tryAcquireMutation('delete-session:session-1'), isNull);

    player.reportDialogDisposed(null);
    player.reportRouteClosed();

    expect(
      coordinator.tryAcquireMutation('delete-session:session-1'),
      isNotNull,
    );
  });
}
