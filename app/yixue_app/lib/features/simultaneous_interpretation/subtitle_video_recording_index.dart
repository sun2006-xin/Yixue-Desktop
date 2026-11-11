import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../../core/app_data_directory.dart';

/// One local video recording. Incomplete files remain visible and cannot be
/// deleted from history. A stale partial file may be offered for playback only
/// after bounded MP4 structure checks succeed.
final class SubtitleVideoRecordingEntry {
  const SubtitleVideoRecordingEntry({
    required this.fileName,
    required this.file,
    required this.modifiedAt,
    required this.sizeBytes,
    required this.duration,
    required this.isIncomplete,
    this.canAttemptPlayback = false,
    this.sessionId,
  });

  final String fileName;
  final File file;
  final DateTime modifiedAt;
  final int sizeBytes;
  final Duration duration;
  final bool isIncomplete;
  final bool canAttemptPlayback;
  final String? sessionId;
}

/// Result of a bounded video-history scan. A truncated scan still returns
/// playable entries, while callers can explain that the local folder may hold
/// additional recordings.
final class SubtitleVideoRecordingIndexResult {
  SubtitleVideoRecordingIndexResult({
    required Iterable<SubtitleVideoRecordingEntry> recordings,
    required this.truncated,
  }) : recordings = List<SubtitleVideoRecordingEntry>.unmodifiable(recordings);

  final List<SubtitleVideoRecordingEntry> recordings;
  final bool truncated;
}

/// Safe, bounded index for Windows screen recordings stored under app data.
///
/// This inspects bounded MP4 box metadata, a video track sample table, and a
/// non-empty media-data box. It does not decode video frames, so structurally
/// valid files can still fail in a media player.
final class SubtitleVideoRecordingIndex {
  const SubtitleVideoRecordingIndex._();

  static const String directoryRelativePath =
      'simultaneous-interpretation/video-recordings';
  static const int _maxVisitedEntries = 2000;
  static const int _maxMp4Candidates = 500;
  static const int _maxIndexedEntries = 500;
  static const int _maxTopLevelBoxes = 512;
  static const int _maxMovieChildBoxes = 512;
  static const int _maxMp4SampleCount = 10_000_000;
  static const int _maxMp4ChunkCount = 100_000;
  static const int _maxSamplesPerChunk = 1_000_000;
  static const int _minMp4Bytes = 32;
  static const Duration _staleIncompleteFileMinAge = Duration(minutes: 2);
  static const int _maxMp4Bytes = 1 << 50;
  static const int _fileAttributeDirectory = 0x10;
  static const int _fileAttributeReparsePoint = 0x400;
  static const int _invalidFileAttributes = 0xffffffff;
  static final RegExp _recordingSessionIdPattern = RegExp(
    r'^screen-\d{8}-\d{6}-((?:audio-only-)?[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})-\d+-\d+(?:\.partial)?\.mp4$',
    caseSensitive: false,
  );
  static final _GetFileAttributesDart _getFileAttributes =
      DynamicLibrary.open('kernel32.dll')
          .lookupFunction<_GetFileAttributesNative, _GetFileAttributesDart>(
            'GetFileAttributesW',
          );

  /// Lists completed MP4 files with duration metadata, a video track, video
  /// samples, and media data. Stable partial files are parsed only after a
  /// minimum quiet period and are offered for a playback attempt only when the
  /// same structural checks succeed.
  static Future<List<SubtitleVideoRecordingEntry>> list({
    required Directory appDataDirectory,
  }) async =>
      (await listWithStatus(appDataDirectory: appDataDirectory)).recordings;

  static Future<SubtitleVideoRecordingIndexResult> listWithStatus({
    required Directory appDataDirectory,
  }) async {
    final recordingDirectory = await resolveDirectory(
      appDataDirectory: appDataDirectory,
    );
    if (recordingDirectory == null) {
      return SubtitleVideoRecordingIndexResult(
        recordings: const <SubtitleVideoRecordingEntry>[],
        truncated: false,
      );
    }

    final entries = <SubtitleVideoRecordingEntry>[];
    final candidates =
        <({FileSystemEntity entity, String fileName, FileStat stat})>[];
    var visited = 0;
    var mp4Candidates = 0;
    var truncated = false;
    await for (final entity in recordingDirectory.list(followLinks: false)) {
      if (visited >= _maxVisitedEntries) {
        truncated = true;
        break;
      }
      visited++;
      final fileName = _basename(entity.path);
      if (!_isMp4Name(fileName)) continue;
      mp4Candidates++;
      if (!await _isOrdinaryFile(entity.path)) continue;
      try {
        final file = File(entity.path);
        final stat = await file.stat();
        if (stat.type != FileSystemEntityType.file ||
            stat.size > _maxMp4Bytes) {
          continue;
        }
        candidates.add((entity: entity, fileName: fileName, stat: stat));
      } on Object {
        // A missing or unreadable video does not block other entries.
      }
    }
    candidates.sort((left, right) {
      final byTime = right.stat.modified.compareTo(left.stat.modified);
      return byTime != 0 ? byTime : left.fileName.compareTo(right.fileName);
    });
    if (mp4Candidates > _maxMp4Candidates ||
        candidates.length > _maxIndexedEntries) {
      truncated = true;
    }
    final selectedCandidates = candidates.take(_maxIndexedEntries);
    for (final candidate in selectedCandidates) {
      final entity = candidate.entity;
      final fileName = candidate.fileName;
      final stat = candidate.stat;
      if (!await _isOrdinaryFile(entity.path)) continue;
      try {
        final file = File(entity.path);
        final isPartial = _isPartialMp4Name(fileName);
        if (stat.type != FileSystemEntityType.file ||
            stat.size > _maxMp4Bytes) {
          continue;
        }
        if (isPartial || stat.size < _minMp4Bytes) {
          final refreshedStat = await file.stat();
          if (refreshedStat.type != FileSystemEntityType.file ||
              refreshedStat.size != stat.size ||
              refreshedStat.modified != stat.modified ||
              !await _isOrdinaryFile(entity.path)) {
            continue;
          }
          final partialDuration =
              isPartial &&
                  refreshedStat.size >= _minMp4Bytes &&
                  DateTime.now().difference(refreshedStat.modified) >=
                      _staleIncompleteFileMinAge
              ? await _readMovieDuration(file, refreshedStat.size)
              : null;
          final verifiedStat = await file.stat();
          if (verifiedStat.type != FileSystemEntityType.file ||
              verifiedStat.size != refreshedStat.size ||
              verifiedStat.modified != refreshedStat.modified ||
              !await _isOrdinaryFile(entity.path)) {
            continue;
          }
          entries.add(
            SubtitleVideoRecordingEntry(
              fileName: fileName,
              file: file,
              modifiedAt: verifiedStat.modified,
              sizeBytes: verifiedStat.size,
              duration: partialDuration ?? Duration.zero,
              isIncomplete: true,
              canAttemptPlayback: partialDuration != null,
              sessionId: _sessionIdFromFileName(fileName),
            ),
          );
          continue;
        }
        final duration = await _readMovieDuration(file, stat.size);
        final refreshedStat = await file.stat();
        if (refreshedStat.type != FileSystemEntityType.file ||
            refreshedStat.size != stat.size ||
            refreshedStat.modified != stat.modified) {
          continue;
        }
        if (duration == null) {
          if (!await _isOrdinaryFile(entity.path)) continue;
          entries.add(
            SubtitleVideoRecordingEntry(
              fileName: fileName,
              file: file,
              modifiedAt: refreshedStat.modified,
              sizeBytes: refreshedStat.size,
              duration: Duration.zero,
              isIncomplete: true,
              canAttemptPlayback: false,
              sessionId: _sessionIdFromFileName(fileName),
            ),
          );
          continue;
        }
        if (!await _isOrdinaryFile(entity.path)) continue;
        entries.add(
          SubtitleVideoRecordingEntry(
            fileName: fileName,
            file: file,
            modifiedAt: refreshedStat.modified,
            sizeBytes: refreshedStat.size,
            duration: duration,
            isIncomplete: false,
            canAttemptPlayback: true,
            sessionId: _sessionIdFromFileName(fileName),
          ),
        );
      } on Object {
        // A corrupt or concurrently changed video does not block other entries.
      }
    }
    entries.sort((left, right) {
      final byTime = right.modifiedAt.compareTo(left.modifiedAt);
      return byTime != 0 ? byTime : left.fileName.compareTo(right.fileName);
    });
    return SubtitleVideoRecordingIndexResult(
      recordings: entries,
      truncated: truncated,
    );
  }

  /// Resolves the fixed recording directory without traversing a link or
  /// Windows reparse point. Returns null when that directory is absent.
  static Future<Directory?> resolveDirectory({
    required Directory appDataDirectory,
  }) async {
    var current = Directory(appDataDirectory.absolute.path);
    final rootKind = await _pathKind(current.path);
    if (rootKind == _SafePathKind.absent) return null;
    if (rootKind != _SafePathKind.directory) {
      throw FileSystemException(
        'App-data directory is a link, reparse point, or not a directory.',
        current.path,
      );
    }
    for (final segment in const <String>[
      'simultaneous-interpretation',
      'video-recordings',
    ]) {
      current = Directory(joinAppDataPath(current.path, segment));
      final kind = await _pathKind(current.path);
      if (kind == _SafePathKind.absent) return null;
      if (kind != _SafePathKind.directory) {
        throw FileSystemException(
          'Video recording directory contains a link or reparse point.',
          current.path,
        );
      }
    }
    return current;
  }

  /// Revalidates one indexed filename before deleting only that file.
  /// Returns false for incomplete recordings, which are kept for recovery.
  static Future<bool> deleteRecording({
    required Directory appDataDirectory,
    required String fileName,
  }) async {
    if (_isPartialMp4Name(fileName) && fileName == _basename(fileName)) {
      return false;
    }
    if (!_isMp4Name(fileName) || fileName != _basename(fileName)) {
      throw ArgumentError.value(fileName, 'fileName', 'Invalid MP4 filename.');
    }
    final recordingDirectory = await resolveDirectory(
      appDataDirectory: appDataDirectory,
    );
    if (recordingDirectory == null) return false;
    final file = File(joinAppDataPath(recordingDirectory.path, fileName));
    if (!await _isOrdinaryFile(file.path)) return false;
    try {
      final stat = await file.stat();
      if (stat.type != FileSystemEntityType.file ||
          stat.size < _minMp4Bytes ||
          stat.size > _maxMp4Bytes ||
          await _readMovieDuration(file, stat.size) == null ||
          !await _isOrdinaryFile(file.path)) {
        return false;
      }
      await file.delete();
      return true;
    } on FileSystemException {
      return false;
    }
  }

  /// Deletes one stale incomplete MP4 after an explicit user confirmation.
  ///
  /// Only a basename under the fixed local video-recording directory is
  /// accepted. The file must be quiet for the same bounded period used before
  /// attempting playback, remain unchanged during validation, and still be
  /// structurally incomplete. A partial MP4 can be recoverable, so callers
  /// must clearly warn that deletion removes that recovery option.
  static Future<bool> deleteIncompleteRecording({
    required Directory appDataDirectory,
    required String fileName,
  }) async {
    if (!_isMp4Name(fileName) || fileName != _basename(fileName)) {
      throw ArgumentError.value(fileName, 'fileName', 'Invalid MP4 filename.');
    }
    final recordingDirectory = await resolveDirectory(
      appDataDirectory: appDataDirectory,
    );
    if (recordingDirectory == null) return false;
    final file = File(joinAppDataPath(recordingDirectory.path, fileName));
    if (!await _isOrdinaryFile(file.path)) return false;
    try {
      final before = await file.stat();
      if (before.type != FileSystemEntityType.file ||
          before.size > _maxMp4Bytes ||
          DateTime.now().difference(before.modified) <
              _staleIncompleteFileMinAge) {
        return false;
      }
      final isPartial = _isPartialMp4Name(fileName);
      final duration = await _readMovieDuration(file, before.size);
      if (!isPartial && duration != null) return false;
      final after = await file.stat();
      if (after.type != FileSystemEntityType.file ||
          after.size != before.size ||
          after.modified != before.modified ||
          !await _isOrdinaryFile(file.path)) {
        return false;
      }
      await file.delete();
      return true;
    } on FileSystemException {
      return false;
    }
  }

  /// Re-resolves a playable MP4 immediately before in-app playback.
  ///
  /// Malformed, recently changed, replaced, linked, or reparse-point files are
  /// never returned. A stable partial MP4 may be returned for a playback
  /// attempt when the bounded container and video sample checks succeed. This
  /// does not repair or modify the source file; the decoder still reports
  /// unsupported codecs or missing frames.
  static Future<File?> resolvePlayableRecording({
    required Directory appDataDirectory,
    required String fileName,
  }) async {
    if (!_isMp4Name(fileName) || fileName != _basename(fileName)) {
      throw ArgumentError.value(fileName, 'fileName', 'Invalid MP4 filename.');
    }
    final recordingDirectory = await resolveDirectory(
      appDataDirectory: appDataDirectory,
    );
    if (recordingDirectory == null) return null;
    final file = File(joinAppDataPath(recordingDirectory.path, fileName));
    if (!await _isOrdinaryFile(file.path)) return null;
    try {
      final stat = await file.stat();
      if (stat.type != FileSystemEntityType.file ||
          stat.size < _minMp4Bytes ||
          stat.size > _maxMp4Bytes ||
          (_isPartialMp4Name(fileName) &&
              DateTime.now().difference(stat.modified) <
                  _staleIncompleteFileMinAge) ||
          await _readMovieDuration(file, stat.size) == null ||
          !await _isOrdinaryFile(file.path)) {
        return null;
      }
      final refreshedStat = await file.stat();
      if (refreshedStat.type != FileSystemEntityType.file ||
          refreshedStat.size != stat.size ||
          refreshedStat.modified != stat.modified) {
        return null;
      }
      return file;
    } on FileSystemException {
      return null;
    }
  }

  static bool _isMp4Name(String fileName) =>
      fileName.length > 4 && fileName.toLowerCase().endsWith('.mp4');

  static String? _sessionIdFromFileName(String fileName) =>
      _recordingSessionIdPattern.firstMatch(fileName)?.group(1)?.toLowerCase();

  static bool _isPartialMp4Name(String fileName) =>
      fileName.toLowerCase().endsWith('.partial.mp4');

  static String _basename(String path) =>
      path.replaceAll('\\', '/').split('/').last;

  static Future<bool> _isOrdinaryFile(String path) async =>
      await _pathKind(path) == _SafePathKind.file;

  static Future<_SafePathKind> _pathKind(String path) async {
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return _SafePathKind.absent;
    if (type == FileSystemEntityType.link) return _SafePathKind.unsafe;
    if (Platform.isWindows) {
      final attributes = _windowsFileAttributes(path);
      if (attributes == _invalidFileAttributes ||
          attributes & _fileAttributeReparsePoint != 0) {
        return _SafePathKind.unsafe;
      }
      final isDirectory = attributes & _fileAttributeDirectory != 0;
      if (type == FileSystemEntityType.directory && isDirectory) {
        return _SafePathKind.directory;
      }
      if (type == FileSystemEntityType.file && !isDirectory) {
        return _SafePathKind.file;
      }
      return _SafePathKind.unsafe;
    }
    if (type == FileSystemEntityType.directory) return _SafePathKind.directory;
    if (type == FileSystemEntityType.file) return _SafePathKind.file;
    return _SafePathKind.unsafe;
  }

  static int _windowsFileAttributes(String path) {
    final nativePath = path.toNativeUtf16();
    try {
      return _getFileAttributes(nativePath);
    } finally {
      calloc.free(nativePath);
    }
  }

  static Future<Duration?> _readMovieDuration(File file, int fileLength) async {
    RandomAccessFile? handle;
    try {
      handle = await file.open(mode: FileMode.read);
      var offset = 0;
      _Mp4Box? movieBox;
      final mediaDataRanges = <_Mp4ByteRange>[];
      for (
        var index = 0;
        index < _maxTopLevelBoxes && offset < fileLength;
        index++
      ) {
        final box = await _readBox(handle, offset, fileLength);
        if (box == null) return null;
        if (box.type == 'moov') {
          if (movieBox != null) return null;
          movieBox = box;
        } else if (box.type == 'mdat' && box.payloadSize > 0) {
          mediaDataRanges.add(
            _Mp4ByteRange(start: box.payloadOffset, end: box.endOffset),
          );
        }
        offset = box.endOffset;
      }
      if (offset != fileLength || movieBox == null || mediaDataRanges.isEmpty) {
        return null;
      }
      final metadata = await _readMovieMetadata(
        handle,
        movieBox,
        mediaDataRanges,
      );
      return metadata?.hasVideoSamples == true ? metadata!.duration : null;
    } on Object {
      return null;
    } finally {
      await handle?.close();
    }
  }

  static Future<_Mp4MovieMetadata?> _readMovieMetadata(
    RandomAccessFile handle,
    _Mp4Box movieBox,
    List<_Mp4ByteRange> mediaDataRanges,
  ) async {
    var offset = movieBox.payloadOffset;
    Duration? duration;
    var hasVideoSamples = false;
    for (
      var index = 0;
      index < _maxMovieChildBoxes && offset < movieBox.endOffset;
      index++
    ) {
      final box = await _readBox(handle, offset, movieBox.endOffset);
      if (box == null) return null;
      if (box.type == 'mvhd') {
        if (duration != null) return null;
        duration = await _readMvhdDuration(handle, box);
        if (duration == null) return null;
      } else if (box.type == 'trak' &&
          await _trackHasVideoSamples(handle, box, mediaDataRanges)) {
        hasVideoSamples = true;
      }
      offset = box.endOffset;
    }
    if (offset != movieBox.endOffset || duration == null) return null;
    return _Mp4MovieMetadata(
      duration: duration,
      hasVideoSamples: hasVideoSamples,
    );
  }

  static Future<bool> _trackHasVideoSamples(
    RandomAccessFile handle,
    _Mp4Box trackBox,
    List<_Mp4ByteRange> mediaDataRanges,
  ) async {
    var offset = trackBox.payloadOffset;
    _Mp4Box? mediaBox;
    for (
      var index = 0;
      index < _maxMovieChildBoxes && offset < trackBox.endOffset;
      index++
    ) {
      final box = await _readBox(handle, offset, trackBox.endOffset);
      if (box == null) return false;
      if (box.type == 'mdia') {
        if (mediaBox != null) return false;
        mediaBox = box;
      }
      offset = box.endOffset;
    }
    if (offset != trackBox.endOffset || mediaBox == null) return false;

    offset = mediaBox.payloadOffset;
    String? handlerType;
    _Mp4Box? mediaInformationBox;
    for (
      var index = 0;
      index < _maxMovieChildBoxes && offset < mediaBox.endOffset;
      index++
    ) {
      final box = await _readBox(handle, offset, mediaBox.endOffset);
      if (box == null) return false;
      if (box.type == 'hdlr') {
        if (handlerType != null) return false;
        handlerType = await _readHandlerType(handle, box);
        if (handlerType == null) return false;
      } else if (box.type == 'minf') {
        if (mediaInformationBox != null) return false;
        mediaInformationBox = box;
      }
      offset = box.endOffset;
    }
    if (offset != mediaBox.endOffset || handlerType != 'vide') return false;
    if (mediaInformationBox == null) return false;
    return _mediaInformationHasVideoSamples(
      handle,
      mediaInformationBox,
      mediaDataRanges,
    );
  }

  static Future<String?> _readHandlerType(
    RandomAccessFile handle,
    _Mp4Box box,
  ) async {
    if (box.payloadSize < 12) return null;
    await handle.setPosition(box.payloadOffset + 8);
    final bytes = await handle.read(4);
    if (bytes.length != 4) return null;
    return String.fromCharCodes(bytes);
  }

  static Future<bool> _mediaInformationHasVideoSamples(
    RandomAccessFile handle,
    _Mp4Box mediaInformationBox,
    List<_Mp4ByteRange> mediaDataRanges,
  ) async {
    var offset = mediaInformationBox.payloadOffset;
    _Mp4Box? sampleTableBox;
    for (
      var index = 0;
      index < _maxMovieChildBoxes && offset < mediaInformationBox.endOffset;
      index++
    ) {
      final box = await _readBox(handle, offset, mediaInformationBox.endOffset);
      if (box == null) return false;
      if (box.type == 'stbl') {
        if (sampleTableBox != null) return false;
        sampleTableBox = box;
      }
      offset = box.endOffset;
    }
    if (offset != mediaInformationBox.endOffset || sampleTableBox == null) {
      return false;
    }

    offset = sampleTableBox.payloadOffset;
    _Mp4Box? sampleDescriptionBox;
    _Mp4Box? sampleSizeBox;
    _Mp4Box? sampleToChunkBox;
    _Mp4Box? chunkOffsetBox;
    for (
      var index = 0;
      index < _maxMovieChildBoxes && offset < sampleTableBox.endOffset;
      index++
    ) {
      final box = await _readBox(handle, offset, sampleTableBox.endOffset);
      if (box == null) return false;
      if (box.type == 'stsd') {
        if (sampleDescriptionBox != null) return false;
        sampleDescriptionBox = box;
      } else if (box.type == 'stsz') {
        if (sampleSizeBox != null) return false;
        sampleSizeBox = box;
      } else if (box.type == 'stsc') {
        if (sampleToChunkBox != null) return false;
        sampleToChunkBox = box;
      } else if (box.type == 'stco' || box.type == 'co64') {
        if (chunkOffsetBox != null) return false;
        chunkOffsetBox = box;
      }
      offset = box.endOffset;
    }
    if (offset != sampleTableBox.endOffset ||
        sampleDescriptionBox == null ||
        sampleSizeBox == null ||
        sampleToChunkBox == null ||
        chunkOffsetBox == null) {
      return false;
    }

    final sampleDescriptionCount = await _readVideoSampleDescriptions(
      handle,
      sampleDescriptionBox,
    );
    if (sampleDescriptionCount == null) return false;
    final sampleSizes = await _readSampleSizeTable(handle, sampleSizeBox);
    if (sampleSizes == null) return false;
    final chunkRules = await _readSampleToChunkTable(
      handle,
      sampleToChunkBox,
      sampleDescriptionCount,
    );
    if (chunkRules == null) return false;
    final chunkOffsets = await _readChunkOffsets(handle, chunkOffsetBox);
    if (chunkOffsets == null ||
        chunkOffsets.isEmpty ||
        chunkRules.last.firstChunk > chunkOffsets.length) {
      return false;
    }
    return _sampleChunksAreInsideMediaData(
      handle,
      sampleSizes,
      chunkRules,
      chunkOffsets,
      mediaDataRanges,
    );
  }

  static Future<int?> _readVideoSampleDescriptions(
    RandomAccessFile handle,
    _Mp4Box box,
  ) async {
    if (box.payloadSize < 8) return null;
    await handle.setPosition(box.payloadOffset + 4);
    final countBytes = await handle.read(4);
    if (countBytes.length != 4) return null;
    final count = ByteData.sublistView(countBytes).getUint32(0, Endian.big);
    if (count == 0 || count > 16) return null;
    var offset = box.payloadOffset + 8;
    var videoEntryCount = 0;
    for (var index = 0; index < count; index++) {
      final entry = await _readBox(handle, offset, box.endOffset);
      if (entry == null || entry.payloadSize < 78) return null;
      if (const <String>{
        'avc1',
        'avc3',
        'hvc1',
        'hev1',
        'mp4v',
        'vp09',
        'av01',
      }.contains(entry.type)) {
        videoEntryCount++;
      } else {
        return null;
      }
      offset = entry.endOffset;
    }
    if (offset != box.endOffset || videoEntryCount != count) return null;
    return count;
  }

  static Future<_Mp4SampleSizeTable?> _readSampleSizeTable(
    RandomAccessFile handle,
    _Mp4Box box,
  ) async {
    if (box.payloadSize < 12) return null;
    await handle.setPosition(box.payloadOffset + 4);
    final bytes = await handle.read(8);
    if (bytes.length != 8) return null;
    final data = ByteData.sublistView(bytes);
    final fixedSampleSize = data.getUint32(0, Endian.big);
    final sampleCount = data.getUint32(4, Endian.big);
    if (sampleCount == 0 || sampleCount > _maxMp4SampleCount) return null;
    final expectedPayloadSize = fixedSampleSize == 0
        ? 12 + sampleCount * 4
        : 12;
    if (box.payloadSize != expectedPayloadSize) return null;
    return _Mp4SampleSizeTable(
      fixedSampleSize: fixedSampleSize,
      sampleCount: sampleCount,
      variableSizesOffset: box.payloadOffset + 12,
    );
  }

  static Future<List<_Mp4ChunkRule>?> _readSampleToChunkTable(
    RandomAccessFile handle,
    _Mp4Box box,
    int sampleDescriptionCount,
  ) async {
    if (box.payloadSize < 8) return null;
    await handle.setPosition(box.payloadOffset + 4);
    final countBytes = await handle.read(4);
    if (countBytes.length != 4) return null;
    final count = ByteData.sublistView(countBytes).getUint32(0, Endian.big);
    if (count == 0 ||
        count > _maxMp4ChunkCount ||
        box.payloadSize != 8 + count * 12) {
      return null;
    }
    final rules = <_Mp4ChunkRule>[];
    var previousFirstChunk = 0;
    await handle.setPosition(box.payloadOffset + 8);
    for (var index = 0; index < count; index++) {
      final bytes = await handle.read(12);
      if (bytes.length != 12) return null;
      final data = ByteData.sublistView(bytes);
      final firstChunk = data.getUint32(0, Endian.big);
      final samplesPerChunk = data.getUint32(4, Endian.big);
      final sampleDescriptionIndex = data.getUint32(8, Endian.big);
      if (firstChunk == 0 ||
          firstChunk <= previousFirstChunk ||
          samplesPerChunk == 0 ||
          samplesPerChunk > _maxSamplesPerChunk ||
          sampleDescriptionIndex == 0 ||
          sampleDescriptionIndex > sampleDescriptionCount) {
        return null;
      }
      rules.add(
        _Mp4ChunkRule(firstChunk: firstChunk, samplesPerChunk: samplesPerChunk),
      );
      previousFirstChunk = firstChunk;
    }
    return rules.first.firstChunk == 1 ? rules : null;
  }

  static Future<List<int>?> _readChunkOffsets(
    RandomAccessFile handle,
    _Mp4Box box,
  ) async {
    final is64Bit = box.type == 'co64';
    final entryBytes = is64Bit ? 8 : 4;
    if (box.payloadSize < 8) return null;
    await handle.setPosition(box.payloadOffset + 4);
    final countBytes = await handle.read(4);
    if (countBytes.length != 4) return null;
    final count = ByteData.sublistView(countBytes).getUint32(0, Endian.big);
    if (count == 0 ||
        count > _maxMp4ChunkCount ||
        box.payloadSize != 8 + count * entryBytes) {
      return null;
    }
    final offsets = <int>[];
    await handle.setPosition(box.payloadOffset + 8);
    for (var index = 0; index < count; index++) {
      final bytes = await handle.read(entryBytes);
      if (bytes.length != entryBytes) return null;
      final data = ByteData.sublistView(bytes);
      offsets.add(
        is64Bit ? data.getUint64(0, Endian.big) : data.getUint32(0, Endian.big),
      );
    }
    return offsets;
  }

  static Future<bool> _sampleChunksAreInsideMediaData(
    RandomAccessFile handle,
    _Mp4SampleSizeTable sampleSizes,
    List<_Mp4ChunkRule> chunkRules,
    List<int> chunkOffsets,
    List<_Mp4ByteRange> mediaDataRanges,
  ) async {
    var sampleIndex = 0;
    var ruleIndex = 0;
    for (var chunkIndex = 1; chunkIndex <= chunkOffsets.length; chunkIndex++) {
      while (ruleIndex + 1 < chunkRules.length &&
          chunkRules[ruleIndex + 1].firstChunk <= chunkIndex) {
        ruleIndex++;
      }
      final samplesPerChunk = chunkRules[ruleIndex].samplesPerChunk;
      if (samplesPerChunk > sampleSizes.sampleCount - sampleIndex) return false;
      var chunkBytes = 0;
      if (sampleSizes.fixedSampleSize > 0) {
        chunkBytes = sampleSizes.fixedSampleSize * samplesPerChunk;
      } else {
        var samplesRemaining = samplesPerChunk;
        while (samplesRemaining > 0) {
          final batchCount = samplesRemaining < 8192 ? samplesRemaining : 8192;
          final batchStart = sampleSizes.variableSizesOffset + sampleIndex * 4;
          await handle.setPosition(batchStart);
          final bytes = await handle.read(batchCount * 4);
          if (bytes.length != batchCount * 4) return false;
          final data = ByteData.sublistView(bytes);
          for (var index = 0; index < batchCount; index++) {
            final sampleSize = data.getUint32(index * 4, Endian.big);
            if (sampleSize == 0) return false;
            chunkBytes += sampleSize;
          }
          sampleIndex += batchCount;
          samplesRemaining -= batchCount;
        }
      }
      if (chunkBytes <= 0 ||
          !mediaDataRanges.any(
            (range) =>
                chunkOffsets[chunkIndex - 1] >= range.start &&
                chunkOffsets[chunkIndex - 1] + chunkBytes <= range.end,
          )) {
        return false;
      }
      if (sampleSizes.fixedSampleSize > 0) sampleIndex += samplesPerChunk;
    }
    return sampleIndex == sampleSizes.sampleCount;
  }

  static Future<Duration?> _readMvhdDuration(
    RandomAccessFile handle,
    _Mp4Box box,
  ) async {
    final bytesToRead = box.payloadSize < 32 ? box.payloadSize : 32;
    if (bytesToRead < 20) return null;
    await handle.setPosition(box.payloadOffset);
    final bytes = await handle.read(bytesToRead);
    if (bytes.length != bytesToRead) return null;
    final data = ByteData.sublistView(bytes);
    final version = bytes[0];
    late final int timescale;
    late final double durationTicks;
    if (version == 0) {
      if (bytes.length < 20) return null;
      timescale = data.getUint32(12, Endian.big);
      durationTicks = data.getUint32(16, Endian.big).toDouble();
    } else if (version == 1) {
      if (bytes.length < 32) return null;
      timescale = data.getUint32(20, Endian.big);
      final high = data.getUint32(24, Endian.big);
      final low = data.getUint32(28, Endian.big);
      durationTicks = high * 4294967296.0 + low;
    } else {
      return null;
    }
    if (timescale <= 0 || !durationTicks.isFinite || durationTicks <= 0) {
      return null;
    }
    final seconds = durationTicks / timescale;
    if (!seconds.isFinite || seconds <= 0 || seconds > 10 * 365 * 24 * 3600) {
      return null;
    }
    return Duration(milliseconds: (seconds * 1000).round());
  }

  static Future<_Mp4Box?> _readBox(
    RandomAccessFile handle,
    int offset,
    int containingEnd,
  ) async {
    if (offset < 0 || containingEnd - offset < 8) return null;
    await handle.setPosition(offset);
    final base = await handle.read(8);
    if (base.length != 8) return null;
    final view = ByteData.sublistView(base);
    final size32 = view.getUint32(0, Endian.big);
    final type = String.fromCharCodes(base.sublist(4, 8));
    var headerSize = 8;
    late final int boxSize;
    if (size32 == 1) {
      if (containingEnd - offset < 16) return null;
      final extended = await handle.read(8);
      if (extended.length != 8) return null;
      final extendedView = ByteData.sublistView(extended);
      final high = extendedView.getUint32(0, Endian.big);
      final low = extendedView.getUint32(4, Endian.big);
      final remaining = containingEnd - offset;
      final maximumHigh = remaining ~/ 4294967296;
      final maximumLow = remaining % 4294967296;
      if (high > maximumHigh || (high == maximumHigh && low > maximumLow)) {
        return null;
      }
      boxSize = high * 4294967296 + low;
      headerSize = 16;
    } else if (size32 == 0) {
      boxSize = containingEnd - offset;
    } else {
      boxSize = size32;
    }
    if (boxSize < headerSize || boxSize > containingEnd - offset) return null;
    final payloadOffset = offset + headerSize;
    final endOffset = offset + boxSize;
    return _Mp4Box(
      type: type,
      payloadOffset: payloadOffset,
      payloadSize: boxSize - headerSize,
      endOffset: endOffset,
    );
  }
}

enum _SafePathKind { absent, directory, file, unsafe }

final class _Mp4Box {
  const _Mp4Box({
    required this.type,
    required this.payloadOffset,
    required this.payloadSize,
    required this.endOffset,
  });

  final String type;
  final int payloadOffset;
  final int payloadSize;
  final int endOffset;
}

final class _Mp4MovieMetadata {
  const _Mp4MovieMetadata({
    required this.duration,
    required this.hasVideoSamples,
  });

  final Duration duration;
  final bool hasVideoSamples;
}

final class _Mp4ByteRange {
  const _Mp4ByteRange({required this.start, required this.end});

  final int start;
  final int end;
}

final class _Mp4SampleSizeTable {
  const _Mp4SampleSizeTable({
    required this.fixedSampleSize,
    required this.sampleCount,
    required this.variableSizesOffset,
  });

  final int fixedSampleSize;
  final int sampleCount;
  final int variableSizesOffset;
}

final class _Mp4ChunkRule {
  const _Mp4ChunkRule({
    required this.firstChunk,
    required this.samplesPerChunk,
  });

  final int firstChunk;
  final int samplesPerChunk;
}

typedef _GetFileAttributesNative = Uint32 Function(Pointer<Utf16>);
typedef _GetFileAttributesDart = int Function(Pointer<Utf16>);
