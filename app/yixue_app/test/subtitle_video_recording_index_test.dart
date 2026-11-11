import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/features/simultaneous_interpretation/subtitle_video_recording_index.dart';

void main() {
  test(
    'keeps partial recordings visible and protected after refresh',
    () async {
      final temporaryDirectory = await Directory.systemTemp.createTemp(
        'yixue-video-history-',
      );
      addTearDown(() => temporaryDirectory.delete(recursive: true));

      final recordingsDirectory = Directory(
        '${temporaryDirectory.path}${Platform.pathSeparator}'
        'simultaneous-interpretation${Platform.pathSeparator}'
        'video-recordings',
      );
      await recordingsDirectory.create(recursive: true);
      const sessionId = '1b8a6b19-b11a-44f9-b4a7-ed7093b4186f';
      const partialFileName =
          'screen-20261019-094500-$sessionId-1234-56789.partial.mp4';
      final partialFile = File(
        '${recordingsDirectory.path}${Platform.pathSeparator}$partialFileName',
      );
      final originalBytes = List<int>.generate(128, (index) => index & 0xff);
      await partialFile.writeAsBytes(originalBytes);

      final entries = await SubtitleVideoRecordingIndex.list(
        appDataDirectory: temporaryDirectory,
      );

      expect(entries, hasLength(1));
      expect(entries.single.fileName, partialFileName);
      expect(entries.single.sessionId, sessionId);
      expect(entries.single.isIncomplete, isTrue);
      expect(entries.single.canAttemptPlayback, isFalse);
      expect(entries.single.sizeBytes, 128);
      expect(
        await SubtitleVideoRecordingIndex.resolvePlayableRecording(
          appDataDirectory: temporaryDirectory,
          fileName: partialFileName,
        ),
        isNull,
      );
      expect(
        await SubtitleVideoRecordingIndex.deleteRecording(
          appDataDirectory: temporaryDirectory,
          fileName: partialFileName,
        ),
        isFalse,
      );
      expect(partialFile.existsSync(), isTrue);
      expect(await partialFile.readAsBytes(), originalBytes);

      final refreshedEntries = await SubtitleVideoRecordingIndex.list(
        appDataDirectory: temporaryDirectory,
      );
      expect(refreshedEntries, hasLength(1));
      expect(refreshedEntries.single.isIncomplete, isTrue);
      expect(partialFile.existsSync(), isTrue);
      expect(await partialFile.readAsBytes(), originalBytes);
    },
  );

  test(
    'keeps the newest video when older MP4 candidates exceed the index limit',
    () async {
      final temporaryDirectory = await Directory.systemTemp.createTemp(
        'yixue-video-history-newest-limit-',
      );
      addTearDown(() => temporaryDirectory.delete(recursive: true));

      final recordingsDirectory = Directory(
        '${temporaryDirectory.path}${Platform.pathSeparator}'
        'simultaneous-interpretation${Platform.pathSeparator}'
        'video-recordings',
      );
      await recordingsDirectory.create(recursive: true);
      final oldTime = DateTime.now().subtract(const Duration(seconds: 1));
      for (var index = 0; index < 500; index++) {
        final olderCandidate = File(
          '${recordingsDirectory.path}${Platform.pathSeparator}'
          'older-$index.partial.mp4',
        );
        await olderCandidate.writeAsBytes(List<int>.filled(128, 0));
        await olderCandidate.setLastModified(oldTime);
      }

      const newestFileName = 'newest-valid.mp4';
      final movieBeforeMdat = _movieWithVideoSample(
        mvhdPayload: _testMovieHeaderPayload,
        sampleOffset: 0,
      );
      final movie = _movieWithVideoSample(
        mvhdPayload: _testMovieHeaderPayload,
        sampleOffset: movieBeforeMdat.length + 8,
      );
      final newestFile = File(
        '${recordingsDirectory.path}${Platform.pathSeparator}$newestFileName',
      );
      await newestFile.writeAsBytes(<int>[
        ...movie,
        ..._box('mdat', <int>[1, 2, 3, 4]),
      ]);

      final result = await SubtitleVideoRecordingIndex.listWithStatus(
        appDataDirectory: temporaryDirectory,
      );

      expect(result.truncated, isTrue);
      expect(result.recordings, hasLength(500));
      expect(
        result.recordings.any(
          (recording) => recording.fileName == newestFileName,
        ),
        isTrue,
      );
      expect(result.recordings.first.fileName, newestFileName);
    },
  );

  test('explicitly deletes stale incomplete video only from the local recording folder', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'yixue-video-history-explicit-incomplete-delete-',
    );
    addTearDown(() => temporaryDirectory.delete(recursive: true));

    final recordingsDirectory = Directory(
      '${temporaryDirectory.path}${Platform.pathSeparator}'
      'simultaneous-interpretation${Platform.pathSeparator}'
      'video-recordings',
    );
    await recordingsDirectory.create(recursive: true);
    const stalePartialName =
        'screen-20261019-094500-1b8a6b19-b11a-44f9-b4a7-ed7093b4186f-1234-56789.partial.mp4';
    final stalePartial = File(
      '${recordingsDirectory.path}${Platform.pathSeparator}$stalePartialName',
    );
    await stalePartial.writeAsBytes(List<int>.filled(128, 0));
    await stalePartial.setLastModified(
      DateTime.now().subtract(const Duration(minutes: 3)),
    );

    const validFinalName = 'valid-final-must-not-delete.mp4';
    final movieBeforeMdat = _movieWithVideoSample(
      mvhdPayload: _testMovieHeaderPayload,
      sampleOffset: 0,
    );
    final movie = _movieWithVideoSample(
      mvhdPayload: _testMovieHeaderPayload,
      sampleOffset: movieBeforeMdat.length + 8,
    );
    final validFinal = File(
      '${recordingsDirectory.path}${Platform.pathSeparator}$validFinalName',
    );
    await validFinal.writeAsBytes(<int>[
      ...movie,
      ..._box('mdat', <int>[1, 2, 3, 4]),
    ]);

    final outsideFile = File(
      '${temporaryDirectory.path}${Platform.pathSeparator}outside.partial.mp4',
    );
    await outsideFile.writeAsBytes(List<int>.filled(128, 0));

    expect(
      await SubtitleVideoRecordingIndex.deleteIncompleteRecording(
        appDataDirectory: temporaryDirectory,
        fileName: stalePartialName,
      ),
      isTrue,
    );
    expect(await stalePartial.exists(), isFalse);
    expect(
      await SubtitleVideoRecordingIndex.deleteIncompleteRecording(
        appDataDirectory: temporaryDirectory,
        fileName: validFinalName,
      ),
      isFalse,
    );
    await expectLater(
      SubtitleVideoRecordingIndex.deleteIncompleteRecording(
        appDataDirectory: temporaryDirectory,
        fileName: outsideFile.path,
      ),
      throwsArgumentError,
    );
    expect(await outsideFile.exists(), isTrue);
    expect(await validFinal.exists(), isTrue);
  });

  test('does not delete a recently changed partial that may still be recording', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'yixue-video-history-recent-partial-delete-',
    );
    addTearDown(() => temporaryDirectory.delete(recursive: true));

    final recordingsDirectory = Directory(
      '${temporaryDirectory.path}${Platform.pathSeparator}'
      'simultaneous-interpretation${Platform.pathSeparator}'
      'video-recordings',
    );
    await recordingsDirectory.create(recursive: true);
    const fileName =
        'screen-20261019-094500-1b8a6b19-b11a-44f9-b4a7-ed7093b4186f-1234-56789.partial.mp4';
    final file = File(
      '${recordingsDirectory.path}${Platform.pathSeparator}$fileName',
    );
    await file.writeAsBytes(List<int>.filled(128, 0));

    expect(
      await SubtitleVideoRecordingIndex.deleteIncompleteRecording(
        appDataDirectory: temporaryDirectory,
        fileName: fileName,
      ),
      isFalse,
    );
    expect(await file.exists(), isTrue);
  });

  test(
    'allows playback of a stable partial MP4 only after structural checks',
    () async {
      final temporaryDirectory = await Directory.systemTemp.createTemp(
        'yixue-video-history-recoverable-partial-',
      );
      addTearDown(() => temporaryDirectory.delete(recursive: true));

      final recordingsDirectory = Directory(
        '${temporaryDirectory.path}${Platform.pathSeparator}'
        'simultaneous-interpretation${Platform.pathSeparator}'
        'video-recordings',
      );
      await recordingsDirectory.create(recursive: true);
      const sessionId = '013f85d0-4567-4cd1-89ab-0123456789ab';
      const fileName =
          'screen-20261019-094500-$sessionId-1234-56789.partial.mp4';
      final movieBeforeMdat = _movieWithVideoSample(
        mvhdPayload: _testMovieHeaderPayload,
        sampleOffset: 0,
      );
      final movie = _movieWithVideoSample(
        mvhdPayload: _testMovieHeaderPayload,
        sampleOffset: movieBeforeMdat.length + 8,
      );
      final originalBytes = <int>[
        ...movie,
        ..._box('mdat', <int>[1, 2, 3, 4]),
      ];
      final partialFile = File(
        '${recordingsDirectory.path}${Platform.pathSeparator}$fileName',
      );
      await partialFile.writeAsBytes(originalBytes);
      await partialFile.setLastModified(
        DateTime.now().subtract(const Duration(minutes: 3)),
      );

      final entries = await SubtitleVideoRecordingIndex.list(
        appDataDirectory: temporaryDirectory,
      );

      expect(entries, hasLength(1));
      expect(entries.single.isIncomplete, isTrue);
      expect(entries.single.canAttemptPlayback, isTrue);
      expect(entries.single.duration, const Duration(milliseconds: 1500));
      final playablePartial =
          await SubtitleVideoRecordingIndex.resolvePlayableRecording(
            appDataDirectory: temporaryDirectory,
            fileName: fileName,
          );
      expect(playablePartial?.path, partialFile.path);
      expect(
        await SubtitleVideoRecordingIndex.deleteRecording(
          appDataDirectory: temporaryDirectory,
          fileName: fileName,
        ),
        isFalse,
      );
      expect(await partialFile.readAsBytes(), originalBytes);
    },
  );

  test('links an audio-only session video to its full session id', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'yixue-video-history-audio-only-link-',
    );
    addTearDown(() => temporaryDirectory.delete(recursive: true));

    final recordingsDirectory = Directory(
      '${temporaryDirectory.path}${Platform.pathSeparator}'
      'simultaneous-interpretation${Platform.pathSeparator}'
      'video-recordings',
    );
    await recordingsDirectory.create(recursive: true);
    const audioSessionId = 'audio-only-1b8a6b19-b11a-44f9-b4a7-ed7093b4186f';
    const partialFileName =
        'screen-20261019-094500-$audioSessionId-1234-56789.partial.mp4';
    await File(
      '${recordingsDirectory.path}${Platform.pathSeparator}$partialFileName',
    ).writeAsBytes(List<int>.filled(128, 0));

    final entries = await SubtitleVideoRecordingIndex.list(
      appDataDirectory: temporaryDirectory,
    );

    expect(entries, hasLength(1));
    expect(entries.single.sessionId, audioSessionId);
    expect(entries.single.isIncomplete, isTrue);
  });

  test(
    'keeps empty finalized MP4 files visible as incomplete recovery items',
    () async {
      final temporaryDirectory = await Directory.systemTemp.createTemp(
        'yixue-video-history-empty-final-',
      );
      addTearDown(() => temporaryDirectory.delete(recursive: true));

      final recordingsDirectory = Directory(
        '${temporaryDirectory.path}${Platform.pathSeparator}'
        'simultaneous-interpretation${Platform.pathSeparator}'
        'video-recordings',
      );
      await recordingsDirectory.create(recursive: true);
      const fileName = '同传录屏-2026-10-16T13-49-50.961031.mp4';
      final file = File(
        '${recordingsDirectory.path}${Platform.pathSeparator}$fileName',
      );
      await file.writeAsBytes(const <int>[]);

      final entries = await SubtitleVideoRecordingIndex.list(
        appDataDirectory: temporaryDirectory,
      );

      expect(entries, hasLength(1));
      expect(entries.single.fileName, fileName);
      expect(entries.single.isIncomplete, isTrue);
      expect(entries.single.sizeBytes, 0);
      expect(
        await SubtitleVideoRecordingIndex.resolvePlayableRecording(
          appDataDirectory: temporaryDirectory,
          fileName: fileName,
        ),
        isNull,
      );
      expect(
        await SubtitleVideoRecordingIndex.deleteRecording(
          appDataDirectory: temporaryDirectory,
          fileName: fileName,
        ),
        isFalse,
      );
      expect(await file.exists(), isTrue);
    },
  );

  test('does not accept an audio-only MP4 as a playable video', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'yixue-video-history-no-video-frames-',
    );
    addTearDown(() => temporaryDirectory.delete(recursive: true));

    final recordingsDirectory = Directory(
      '${temporaryDirectory.path}${Platform.pathSeparator}'
      'simultaneous-interpretation${Platform.pathSeparator}'
      'video-recordings',
    );
    await recordingsDirectory.create(recursive: true);
    const fileName = 'audio-only-with-duration.mp4';
    final mvhdPayload = <int>[
      0, 0, 0, 0, // version and flags
      0, 0, 0, 0, // creation time
      0, 0, 0, 0, // modification time
      0, 0, 3, 232, // 1000 ticks per second
      0, 0, 5, 220, // 1500 ms duration
    ];
    final audioTrack = _box(
      'trak',
      _box('mdia', <int>[
        ..._handlerBox('soun'),
        ..._box('minf', _box('stbl', _sampleSizeBox())),
      ]),
    );
    final movie = _box('moov', <int>[
      ..._box('mvhd', mvhdPayload),
      ...audioTrack,
    ]);
    final mediaData = _box('mdat', <int>[1, 2, 3, 4]);
    await File('${recordingsDirectory.path}${Platform.pathSeparator}$fileName')
        .writeAsBytes(<int>[...movie, ...mediaData]);

    final entries = await SubtitleVideoRecordingIndex.list(
      appDataDirectory: temporaryDirectory,
    );

    expect(entries, hasLength(1));
    expect(entries.single.isIncomplete, isTrue);
    expect(entries.single.duration, Duration.zero);
    expect(
      await SubtitleVideoRecordingIndex.resolvePlayableRecording(
        appDataDirectory: temporaryDirectory,
        fileName: fileName,
      ),
      isNull,
    );
  });

  test('accepts a video sample only when its chunk maps inside mdat', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'yixue-video-history-video-track-',
    );
    addTearDown(() => temporaryDirectory.delete(recursive: true));

    final recordingsDirectory = Directory(
      '${temporaryDirectory.path}${Platform.pathSeparator}'
      'simultaneous-interpretation${Platform.pathSeparator}'
      'video-recordings',
    );
    await recordingsDirectory.create(recursive: true);
    const sessionId = '013f85d0-4567-4cd1-89ab-0123456789ab';
    const fileName = 'screen-20261019-094500-$sessionId-1234-56789.mp4';
    final mvhdPayload = <int>[
      0, 0, 0, 0, // version and flags
      0, 0, 0, 0, // creation time
      0, 0, 0, 0, // modification time
      0, 0, 3, 232, // 1000 ticks per second
      0, 0, 5, 220, // 1500 ms duration
    ];
    final movieBeforeMdat = _movieWithVideoSample(
      mvhdPayload: mvhdPayload,
      sampleOffset: 0,
    );
    final sampleOffset = movieBeforeMdat.length + 8;
    final movie = _movieWithVideoSample(
      mvhdPayload: mvhdPayload,
      sampleOffset: sampleOffset,
    );
    final mediaData = _box('mdat', <int>[1, 2, 3, 4]);
    await File('${recordingsDirectory.path}${Platform.pathSeparator}$fileName')
        .writeAsBytes(<int>[...movie, ...mediaData]);

    final entries = await SubtitleVideoRecordingIndex.list(
      appDataDirectory: temporaryDirectory,
    );

    expect(entries, hasLength(1));
    expect(entries.single.fileName, fileName);
    expect(entries.single.sessionId, sessionId);
    expect(entries.single.isIncomplete, isFalse);
    expect(entries.single.duration, const Duration(milliseconds: 1500));
    expect(
      await SubtitleVideoRecordingIndex.resolvePlayableRecording(
        appDataDirectory: temporaryDirectory,
        fileName: fileName,
      ),
      isNotNull,
    );
  });

  test('rejects video samples that point outside the media data', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'yixue-video-history-invalid-sample-range-',
    );
    addTearDown(() => temporaryDirectory.delete(recursive: true));

    final recordingsDirectory = Directory(
      '${temporaryDirectory.path}${Platform.pathSeparator}'
      'simultaneous-interpretation${Platform.pathSeparator}'
      'video-recordings',
    );
    await recordingsDirectory.create(recursive: true);
    const fileName = 'sample-outside-mdat.mp4';
    const mvhdPayload = <int>[
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      3,
      232,
      0,
      0,
      5,
      220,
    ];
    final movie = _movieWithVideoSample(
      mvhdPayload: mvhdPayload,
      sampleOffset: 4096,
    );
    await File('${recordingsDirectory.path}${Platform.pathSeparator}$fileName')
        .writeAsBytes(<int>[
          ...movie,
          ..._box('mdat', <int>[1, 2, 3, 4]),
        ]);

    final entries = await SubtitleVideoRecordingIndex.list(
      appDataDirectory: temporaryDirectory,
    );
    expect(entries, hasLength(1));
    expect(entries.single.isIncomplete, isTrue);
    expect(entries.single.duration, Duration.zero);
    expect(
      await SubtitleVideoRecordingIndex.resolvePlayableRecording(
        appDataDirectory: temporaryDirectory,
        fileName: fileName,
      ),
      isNull,
    );
  });
}

const _testMovieHeaderPayload = <int>[
  0, 0, 0, 0, // version and flags
  0, 0, 0, 0, // creation time
  0, 0, 0, 0, // modification time
  0, 0, 3, 232, // 1000 ticks per second
  0, 0, 5, 220, // 1500 ms duration
];

List<int> _handlerBox(String handlerType) => _box('hdlr', <int>[
  0, 0, 0, 0, // version and flags
  0, 0, 0, 0, // pre-defined
  ...handlerType.codeUnits,
  ...List<int>.filled(12, 0), // reserved and name
]);

List<int> _sampleSizeBox({int sampleSize = 4}) => _box('stsz', <int>[
  0, 0, 0, 0, // version and flags
  ..._uint32(sampleSize),
  0, 0, 0, 1, // one sample
]);

List<int> _movieWithVideoSample({
  required List<int> mvhdPayload,
  required int sampleOffset,
}) => _box('moov', <int>[
  ..._box('mvhd', mvhdPayload),
  ..._box(
    'trak',
    _box('mdia', <int>[
      ..._handlerBox('vide'),
      ..._box(
        'minf',
        _box('stbl', <int>[
          ..._box('stsd', <int>[
            0, 0, 0, 0, // version and flags
            0, 0, 0, 1, // one sample description
            ..._box('avc1', List<int>.filled(78, 0)),
          ]),
          ..._box('stsc', <int>[
            0, 0, 0, 0, // version and flags
            0, 0, 0, 1, // one entry
            0, 0, 0, 1, // first chunk
            0, 0, 0, 1, // one sample per chunk
            0, 0, 0, 1, // sample description index
          ]),
          ..._box('stco', <int>[
            0, 0, 0, 0, // version and flags
            0, 0, 0, 1, // one chunk
            ..._uint32(sampleOffset),
          ]),
          ..._sampleSizeBox(),
        ]),
      ),
    ]),
  ),
]);

List<int> _box(String type, List<int> payload) => <int>[
  ..._uint32(payload.length + 8),
  ...type.codeUnits,
  ...payload,
];

List<int> _uint32(int value) => <int>[
  (value >> 24) & 0xff,
  (value >> 16) & 0xff,
  (value >> 8) & 0xff,
  value & 0xff,
];
