import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/features/simultaneous_interpretation/subtitle_recording_index_scan_registry.dart';
import 'package:yixue_app/features/simultaneous_interpretation/subtitle_video_recording_index.dart';

void main() {
  test(
    'retired scans stay inside a strict per-directory concurrency cap',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'yixue-video-index-scan-registry-cap-',
      );
      addTearDown(() => directory.delete(recursive: true));

      final registry = SubtitleRecordingIndexScanRegistry();
      final firstScan = Completer<SubtitleVideoRecordingIndexResult>();
      final replacement = Completer<SubtitleVideoRecordingIndexResult>();
      final thirdScan = Completer<SubtitleVideoRecordingIndexResult>();
      final finalScan = Completer<SubtitleVideoRecordingIndexResult>();
      var loaderCalls = 0;
      Future<SubtitleVideoRecordingIndexResult> load(
        Completer<SubtitleVideoRecordingIndexResult> scan,
      ) {
        loaderCalls++;
        return scan.future;
      }

      final first = registry.loadVideo(directory, () => load(firstScan));
      expect(registry.releaseTimedOutVideoScan(directory, first), isTrue);
      final second = registry.loadVideo(directory, () => load(replacement));
      replacement.complete(_emptyResult());
      await second;

      final third = registry.loadVideo(directory, () => load(thirdScan));
      expect(loaderCalls, 3);
      expect(
        registry.releaseTimedOutVideoScan(directory, third),
        isFalse,
        reason: 'the first retired scan is still pending, so no third scan may join it',
      );

      firstScan.complete(_emptyResult());
      await first;
      expect(registry.releaseTimedOutVideoScan(directory, third), isTrue);
      final fourth = registry.loadVideo(directory, () => load(finalScan));
      expect(loaderCalls, 4);

      thirdScan.complete(_emptyResult());
      await third;
      expect(
        registry.loadVideo(
          directory,
          () => throw StateError('start fifth scan'),
        ),
        same(fourth),
      );
      finalScan.complete(_emptyResult());
      await fourth;
      expect(loaderCalls, 4);
    },
  );

  test(
    'one explicit retry replaces a timed-out scan without unbounded work',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'yixue-video-index-scan-registry-',
      );
      addTearDown(() => directory.delete(recursive: true));

      final registry = SubtitleRecordingIndexScanRegistry();
      final firstScan = Completer<SubtitleVideoRecordingIndexResult>();
      final retryScan = Completer<SubtitleVideoRecordingIndexResult>();
      var loaderCalls = 0;

      final first = registry.loadVideo(directory, () {
        loaderCalls++;
        return firstScan.future;
      });
      expect(registry.releaseTimedOutVideoScan(directory, first), isTrue);

      final retry = registry.loadVideo(directory, () {
        loaderCalls++;
        return retryScan.future;
      });
      expect(retry, isNot(same(first)));
      expect(
        registry.releaseTimedOutVideoScan(directory, retry),
        isFalse,
        reason: 'a second hung scan must not allow unbounded parallel retries',
      );

      final joinedRetry = registry.loadVideo(directory, () {
        loaderCalls++;
        return Future<SubtitleVideoRecordingIndexResult>.error(
          StateError('a third scan should not be started'),
        );
      });
      expect(joinedRetry, same(retry));
      expect(loaderCalls, 2);

      firstScan.complete(
        SubtitleVideoRecordingIndexResult(
          recordings: const <SubtitleVideoRecordingEntry>[],
          truncated: false,
        ),
      );
      await first;
      expect(
        registry.loadVideo(directory, () => retryScan.future),
        same(retry),
        reason:
            'completion of the retired scan must not evict the active retry',
      );

      retryScan.complete(
        SubtitleVideoRecordingIndexResult(
          recordings: const <SubtitleVideoRecordingEntry>[],
          truncated: false,
        ),
      );
      await retry;

      final afterRecovery = registry.loadVideo(directory, () {
        loaderCalls++;
        return Future<SubtitleVideoRecordingIndexResult>.value(
          SubtitleVideoRecordingIndexResult(
            recordings: const <SubtitleVideoRecordingEntry>[],
            truncated: false,
          ),
        );
      });
      await afterRecovery;
      expect(loaderCalls, 3);
    },
  );
}

SubtitleVideoRecordingIndexResult _emptyResult() =>
    SubtitleVideoRecordingIndexResult(
      recordings: const <SubtitleVideoRecordingEntry>[],
      truncated: false,
    );
