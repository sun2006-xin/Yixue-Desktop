import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'asr_language_registry.dart';
import 'subtitle_exporter.dart';
import 'subtitle_audio_recording.dart';
import 'subtitle_post_session_service.dart';
import 'subtitle_session_contract.dart';
import 'subtitle_text_presentation.dart';
import 'subtitle_session_store.dart';
import 'subtitle_video_recording_index.dart';
import 'recording_media_player_dialog.dart';
import 'subtitle_media_playback_coordinator.dart';
import 'subtitle_recording_index_scan_registry.dart';

@visibleForTesting
bool subtitleHistorySessionHasActiveAudioPlayback(
  String sessionId,
  Set<String> playbackKeys,
) => playbackKeys.any((key) => key.startsWith('$sessionId:'));

@visibleForTesting
bool subtitleHistoryRecordingHasActiveAudioPlayback(
  String sessionId,
  String recordingId,
  Set<String> playbackKeys,
) => playbackKeys.any((key) => key.startsWith('$sessionId:$recordingId:'));

/// Saved local subtitle history, export, and on-demand post-session review.
final class SubtitleSessionHistoryPage extends StatefulWidget {
  const SubtitleSessionHistoryPage({
    required this.store,
    required this.reviewStore,
    this.appDataDirectory,
    this.postSessionGenerator,
    this.audioRecordingLoader,
    this.videoRecordingLoader,
    @visibleForTesting this.sessionAudioDirectoryResolverForTesting,
    @visibleForTesting this.videoPlayableRecordingResolverForTesting,
    @visibleForTesting this.audioRecordingResolverForTesting,
    this.preferExternalRecordingPlayerForTesting,
    this.recordingPlaybackControllerFactoryForTesting,
    @visibleForTesting this.recordingSystemPlayerLauncherForTesting,
    @visibleForTesting this.incompleteVideoDeleterForTesting,
    super.key,
  });

  final SubtitleSessionStore store;
  final SubtitlePostSessionReviewStore reviewStore;
  final SubtitlePostSessionGenerator? postSessionGenerator;
  final Directory? appDataDirectory;
  @visibleForTesting
  final Future<List<SubtitleAudioIndexedRecording>> Function(
    Directory directory,
  )?
  audioRecordingLoader;
  @visibleForTesting
  final Future<List<SubtitleVideoRecordingEntry>> Function(Directory directory)?
  videoRecordingLoader;
  @visibleForTesting
  final Future<Directory?> Function(Directory directory, String sessionId)?
  sessionAudioDirectoryResolverForTesting;
  @visibleForTesting
  final Future<File?> Function(Directory directory, String fileName)?
  videoPlayableRecordingResolverForTesting;
  @visibleForTesting
  final Future<SubtitleAudioIndexedRecording?> Function(
    Directory directory,
    SubtitleAudioIndexedRecording recording,
  )?
  audioRecordingResolverForTesting;
  @visibleForTesting
  final bool? preferExternalRecordingPlayerForTesting;
  @visibleForTesting
  final RecordingPlaybackControllerFactory?
  recordingPlaybackControllerFactoryForTesting;
  @visibleForTesting
  final Future<void> Function(File file)?
  recordingSystemPlayerLauncherForTesting;
  @visibleForTesting
  final Future<bool> Function(Directory directory, String fileName)?
  incompleteVideoDeleterForTesting;

  @override
  State<SubtitleSessionHistoryPage> createState() =>
      _SubtitleSessionHistoryPageState();
}

final class _SubtitleSessionHistoryPageState
    extends State<SubtitleSessionHistoryPage> {
  static const _exporter = SubtitleExporter();
  static const _retentionChoices = <int>[30, 90, 365];
  static const _historyReadTimeout = Duration(seconds: 15);
  static const _sessionPageSize = 40;
  static const _mediaPageSize = 24;
  static const _metadataLookupBatchSize = 16;
  static final _recordingIndexScans =
      SubtitleRecordingIndexScanRegistry.instance;
  final _mediaPlaybackCoordinator = SubtitleMediaPlaybackCoordinator.instance;

  List<SubtitleSessionRecord> _sessions = const <SubtitleSessionRecord>[];
  final FocusNode _historyFocusNode = FocusNode(
    debugLabel: 'subtitle-history-page',
  );
  final ScrollController _historyScrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();
  final Set<String> _busySessions = <String>{};
  final Set<String> _busyStandaloneRecordings = <String>{};
  final Set<String> _busyAudioFiles = <String>{};
  final Set<String> _selectedSessionIds = <String>{};
  final Set<String> _busyVideoRecordings = <String>{};
  String? _activeMediaPlaybackKey;
  final Set<String> _reviewBusySessions = <String>{};
  final Map<String, _SavedSessionReview> _reviews = {};
  final Map<String, String> _reviewErrors = {};
  final Map<String, Directory?> _audioRecordingDirectories = {};
  final Map<String, List<SubtitleAudioIndexedRecording>>
  _sessionAudioRecordings = {};
  final Map<String, Future<SubtitleAudioRecordingIndexResult>>
  _audioRecordingIndexLoads = {};
  final Set<String> _completedAudioRecordingIndexLoads = <String>{};
  Future<void> _historyMetadataLoadTail = Future<void>.value();
  List<SubtitleAudioIndexedRecording> _standaloneAudioRecordings =
      const <SubtitleAudioIndexedRecording>[];
  List<SubtitleVideoRecordingEntry> _videoRecordings =
      const <SubtitleVideoRecordingEntry>[];
  Map<String, List<SubtitleVideoRecordingEntry>> _videoRecordingsBySession =
      const <String, List<SubtitleVideoRecordingEntry>>{};
  var _loading = true;
  var _hasLoadedOnce = false;
  var _refreshing = false;
  var _videoIndexLoading = false;
  var _audioMetadataLoading = false;
  var _bulkDeletingSessions = false;
  var _mediaPlaybackRefreshScheduled = false;
  var _loadGeneration = 0;
  var _pruning = false;
  var _corruptSessionCount = 0;
  String? _error;
  String? _reviewStorageNotice;
  String? _audioIndexNotice;
  String? _videoIndexNotice;
  String _searchQuery = '';
  var _visibleSessionCount = _sessionPageSize;
  var _visibleAudioRecordingCount = _mediaPageSize;
  var _visibleVideoRecordingCount = _mediaPageSize;

  void _resetVisibleMediaCounts() {
    _visibleAudioRecordingCount = _mediaPageSize;
    _visibleVideoRecordingCount = _mediaPageSize;
  }

  List<SubtitleSessionRecord> get _filteredSessions {
    final query = _searchQuery.trim().toLowerCase();
    if (query.isEmpty) return _sessions;
    return _sessions
        .where((session) {
          final started = session.startedAtUtc.toLocal();
          final searchableValues = <String>[
            _sessionTitle(session),
            _kindLabel(session.kind),
            _formatDate(started),
            session.startedAtUtc.toIso8601String(),
            if (session.endedAtUtc != null)
              session.endedAtUtc!.toLocal().toIso8601String(),
            if (session.endedAtUtc != null)
              _formatDate(session.endedAtUtc!.toLocal()),
            _sourceLabel(session.sourceKind),
            session.sourceKind.name,
            session.targetLanguageCode ?? '',
            session.sessionId,
            _sessionStatusLabel(session.status),
            for (final recording in _videoRecordingsForSession(
              session.sessionId,
            )) ...[
              recording.fileName,
              _formatDate(recording.modifiedAt.toLocal()),
              _formatVideoDuration(recording.duration),
            ],
            for (final segment in session.segments) ...[
              segment.transcript.text,
              segment.translatedText ?? '',
              segment.transcript.segmentId,
              segment.transcript.sourceId,
              _sourceLabel(segment.transcript.sourceKind),
              _transcriptLanguageLabel(segment.transcript.languageCode),
              segment.transcript.languageCode,
            ],
          ];
          return searchableValues.any(
            (value) => value.toLowerCase().contains(query),
          );
        })
        .toList(growable: false);
  }

  List<SubtitleSessionRecord> get _bulkDeletableFilteredSessions =>
      _audioMetadataLoading
      ? const <SubtitleSessionRecord>[]
      : _filteredSessions.where(_canBulkDeleteSession).toList(growable: false);

  bool _canBulkDeleteSession(SubtitleSessionRecord session) =>
      !_mediaPlaybackCoordinator.isBusy &&
      !_isActiveSession(session.status) &&
      !_busySessions.contains(session.sessionId) &&
      !_reviewBusySessions.contains(session.sessionId) &&
      !subtitleHistorySessionHasActiveAudioPlayback(
        session.sessionId,
        _busyAudioFiles,
      );

  List<SubtitleAudioIndexedRecording> get _filteredStandaloneRecordings {
    final query = _searchQuery.trim().toLowerCase();
    if (query.isEmpty) return _standaloneAudioRecordings;
    return _standaloneAudioRecordings
        .where((recording) {
          final searchable = <String>[
            recording.sessionId,
            recording.recordingId,
            recording.status.name,
            recording.droppedFrames.toString(),
            recording.discontinuities.toString(),
            recording.lossCountersKnown.toString(),
            _formatDate(recording.startedAtUtc.toLocal()),
            recording.startedAtUtc.toIso8601String(),
            for (final video in _videoRecordingsForSession(
              recording.sessionId,
            )) ...[
              video.fileName,
              _formatDate(video.modifiedAt.toLocal()),
              _formatVideoDuration(video.duration),
            ],
            for (final recordingFile in recording.files) ...[
              recordingFile.sourceKind.name,
              recordingFile.file.path,
            ],
          ];
          return searchable.any((value) => value.toLowerCase().contains(query));
        })
        .toList(growable: false);
  }

  List<SubtitleVideoRecordingEntry> get _filteredVideoRecordings {
    final query = _searchQuery.trim().toLowerCase();
    final linkedSessionIds = <String>{
      ..._sessions.map((session) => session.sessionId),
      ..._standaloneAudioRecordings.map((recording) => recording.sessionId),
    };
    final unlinkedRecordings = _videoRecordings.where((recording) {
      final sessionId = recording.sessionId;
      return sessionId == null || !linkedSessionIds.contains(sessionId);
    });
    if (query.isEmpty) return unlinkedRecordings.toList(growable: false);
    return unlinkedRecordings
        .where((recording) {
          final searchable = <String>[
            recording.fileName,
            _formatDate(recording.modifiedAt.toLocal()),
            recording.modifiedAt.toIso8601String(),
            _formatVideoDuration(recording.duration),
            _formatByteCount(recording.sizeBytes),
          ];
          return searchable.any((value) => value.toLowerCase().contains(query));
        })
        .toList(growable: false);
  }

  List<SubtitleVideoRecordingEntry> _videoRecordingsForSession(
    String sessionId,
  ) =>
      _videoRecordingsBySession[sessionId] ??
      const <SubtitleVideoRecordingEntry>[];

  Map<String, List<SubtitleVideoRecordingEntry>> _indexVideoRecordings(
    Iterable<SubtitleVideoRecordingEntry> recordings,
  ) {
    final grouped = <String, List<SubtitleVideoRecordingEntry>>{};
    for (final recording in recordings) {
      final sessionId = recording.sessionId;
      if (sessionId == null || sessionId.isEmpty) continue;
      grouped
          .putIfAbsent(sessionId, () => <SubtitleVideoRecordingEntry>[])
          .add(recording);
    }
    return Map<String, List<SubtitleVideoRecordingEntry>>.unmodifiable({
      for (final entry in grouped.entries)
        entry.key: List<SubtitleVideoRecordingEntry>.unmodifiable(entry.value),
    });
  }

  @override
  void initState() {
    super.initState();
    _mediaPlaybackCoordinator.addListener(_handleMediaPlaybackChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _historyFocusNode.requestFocus();
    });
    _load(force: true);
  }

  @override
  void dispose() {
    _mediaPlaybackCoordinator.removeListener(_handleMediaPlaybackChanged);
    _historyFocusNode.dispose();
    _historyScrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _handleMediaPlaybackChanged() {
    if (!mounted) return;
    final scheduler = SchedulerBinding.instance;
    if (scheduler.schedulerPhase == SchedulerPhase.idle) {
      setState(() {});
      return;
    }
    if (_mediaPlaybackRefreshScheduled) return;
    _mediaPlaybackRefreshScheduled = true;
    scheduler.addPostFrameCallback((_) {
      _mediaPlaybackRefreshScheduled = false;
      if (mounted) setState(() {});
    });
    scheduler.scheduleFrame();
  }

  bool _blockHistoryMutationDuringMediaPlayback() {
    if (!_mediaPlaybackCoordinator.isBusy) return false;
    _showMessage(
      _mediaPlaybackCoordinator.isMutationBusy
          ? '另一项历史媒体操作仍在进行，请等它完成后再继续。'
          : '媒体仍在播放或释放资源，请等播放器完成后再删除或清理历史。',
    );
    return true;
  }

  SubtitleMediaMutationLease? _tryAcquireMediaMutation(String key) {
    if (_blockHistoryMutationDuringMediaPlayback()) return null;
    final lease = _mediaPlaybackCoordinator.tryAcquireMutation(key);
    if (lease == null && mounted) {
      _showMessage('另一项媒体操作刚刚开始，请稍后重试。');
    }
    return lease;
  }

  void _showMediaBusyMessageForOpen() {
    _showMessage(
      _mediaPlaybackCoordinator.isMutationBusy
          ? '历史媒体正在删除或恢复，请等操作完成后再打开。'
          : '上一条媒体播放器仍在释放资源，暂时不能安全打开新媒体。请稍等；如果长时间未恢复，重启译学后再试。',
    );
  }

  Future<Set<SubtitlePostSessionOutputKind>?> _chooseReviewOutputs(
    SubtitleSessionRecord session,
    SubtitlePostSessionProviderInfo providerInfo,
  ) async {
    final selected = <SubtitlePostSessionOutputKind>{
      SubtitlePostSessionOutputKind.summary,
    };
    return showDialog<Set<SubtitlePostSessionOutputKind>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          final hasSelection = selected.isNotEmpty;
          return AlertDialog(
            title: const Text('生成会后复盘'),
            content: SizedBox(
              width: 480,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('会话：${_sessionTitle(session)}'),
                    const SizedBox(height: 4),
                    Text('处理位置：${providerInfo.processingDestination}'),
                    const SizedBox(height: 12),
                    const Text('选择本次生成内容'),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: selected.contains(
                        SubtitlePostSessionOutputKind.summary,
                      ),
                      title: const Text('会话摘要'),
                      onChanged: (value) => setDialogState(() {
                        if (value == true) {
                          selected.add(SubtitlePostSessionOutputKind.summary);
                        } else {
                          selected.remove(
                            SubtitlePostSessionOutputKind.summary,
                          );
                        }
                      }),
                    ),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: selected.contains(
                        SubtitlePostSessionOutputKind.terminology,
                      ),
                      title: const Text('术语表'),
                      onChanged: (value) => setDialogState(() {
                        if (value == true) {
                          selected.add(
                            SubtitlePostSessionOutputKind.terminology,
                          );
                        } else {
                          selected.remove(
                            SubtitlePostSessionOutputKind.terminology,
                          );
                        }
                      }),
                    ),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: selected.contains(
                        SubtitlePostSessionOutputKind.actionItems,
                      ),
                      title: const Text('行动项'),
                      onChanged: (value) => setDialogState(() {
                        if (value == true) {
                          selected.add(
                            SubtitlePostSessionOutputKind.actionItems,
                          );
                        } else {
                          selected.remove(
                            SubtitlePostSessionOutputKind.actionItems,
                          );
                        }
                      }),
                    ),
                    const SizedBox(height: 8),
                    _ReviewPrivacyNotice(
                      providerInfo: providerInfo,
                      segmentCount: session.segments.length,
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: hasSelection
                    ? () => Navigator.pop(
                        dialogContext,
                        Set<SubtitlePostSessionOutputKind>.unmodifiable(
                          selected,
                        ),
                      )
                    : null,
                child: Text(
                  providerInfo.kind == SubtitlePostSessionProviderKind.remote
                      ? '确认发送并生成'
                      : '在本机生成',
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  SubtitlePostSessionRequest _buildReviewRequest(
    SubtitleSessionRecord session,
    Iterable<SubtitlePostSessionOutputKind> outputs,
  ) => SubtitlePostSessionRequest(
    sessionId: session.sessionId,
    sessionKind: session.kind,
    startedAtUtc: session.startedAtUtc,
    outputs: outputs,
    segments: session.segments.map((segment) {
      final transcript = segment.transcript;
      final hasTranslation =
          segment.translationStatus == SubtitleTranslationStatus.translated;
      return SubtitlePostSessionSourceSegment(
        captureAttemptId: transcript.captureAttemptId,
        segmentId: transcript.segmentId,
        sourceId: transcript.sourceId,
        sourceKind: transcript.sourceKind,
        startMs: transcript.startMs,
        endMs: transcript.endMs,
        sourceLanguageCode: transcript.languageCode,
        targetLanguageCode: session.targetLanguageCode,
        sourceText: transcript.text,
        translatedText: hasTranslation ? segment.translatedText : null,
      );
    }),
  );

  Future<void> _generateReview(SubtitleSessionRecord session) async {
    final generator = widget.postSessionGenerator;
    if (generator == null || _reviewBusySessions.contains(session.sessionId)) {
      return;
    }
    if (_isActiveSession(session.status)) {
      _showMessage('请先停止并保存会话，再生成会后复盘。');
      return;
    }
    if (session.segments.isEmpty) {
      _showMessage('没有已保存的字幕片段可供复盘。');
      return;
    }

    late final SubtitlePostSessionProviderInfo providerInfo;
    try {
      providerInfo = generator.providerInfo;
    } catch (_) {
      _showMessage('无法读取当前复盘 Provider 信息，已阻止发送字幕。');
      return;
    }
    if (!providerInfo.hasUsableDisclosure) {
      _showMessage(
        providerInfo.kind == SubtitlePostSessionProviderKind.remote
            ? '当前远程 Provider 未提供明确的数据目的地，已阻止发送字幕。'
            : '当前复盘 Provider 信息不完整。',
      );
      return;
    }
    final outputs = await _chooseReviewOutputs(session, providerInfo);
    if (outputs == null || outputs.isEmpty || !mounted) return;
    final request = _buildReviewRequest(session, outputs);
    final inputDigest = subtitlePostSessionInputDigest(request);

    try {
      final latestSession = await widget.store.readSession(session.sessionId);
      if (!mounted) return;
      if (latestSession == null ||
          _isActiveSession(latestSession.status) ||
          subtitlePostSessionInputDigest(
                _buildReviewRequest(latestSession, outputs),
              ) !=
              inputDigest) {
        _showMessage('会话状态或字幕内容已变化，已取消复盘。请刷新后重新确认处理位置。');
        await _load(force: true);
        return;
      }
    } catch (_) {
      if (mounted) _showMessage('无法验证最新字幕，已取消复盘。请刷新历史后重试。');
      return;
    }

    var consentedRouteIsCurrent = false;
    try {
      if (identical(widget.postSessionGenerator, generator)) {
        final currentProviderInfo = generator.providerInfo;
        consentedRouteIsCurrent =
            currentProviderInfo.hasUsableDisclosure &&
            _sameProviderRoute(currentProviderInfo, providerInfo);
      }
    } catch (_) {
      // If the route cannot be re-read after consent, fail closed.
    }
    if (!consentedRouteIsCurrent) {
      _showMessage('Provider 或处理位置已变化。请重新打开复盘并确认新的数据去向。');
      return;
    }

    setState(() {
      _reviewBusySessions.add(session.sessionId);
      _reviewErrors.remove(session.sessionId);
    });
    try {
      final result = await generator.generate(request);
      validateSubtitlePostSessionResult(request, result);
      final latestSession = await widget.store.readSession(session.sessionId);
      if (latestSession == null ||
          _isActiveSession(latestSession.status) ||
          subtitlePostSessionInputDigest(
                _buildReviewRequest(latestSession, request.outputs),
              ) !=
              inputDigest) {
        throw const SubtitlePostSessionGenerationException(
          '会话状态或字幕在生成期间发生变化，复盘未保存。请刷新历史后重新生成。',
        );
      }
      final storedReview = SubtitlePostSessionStoredReview(
        sessionId: session.sessionId,
        inputDigest: inputDigest,
        generatedAtUtc: result.generatedAtUtc,
        outputs: request.outputs,
        providerInfo: providerInfo,
        result: result,
      );
      var isPersisted = false;
      try {
        await widget.reviewStore.saveReview(storedReview);
        isPersisted = true;
      } catch (_) {
        _reviewStorageNotice = '复盘已生成，但本机复盘历史保存失败；请检查数据目录空间和权限。';
      }
      if (!mounted) return;
      setState(() {
        _reviews[session.sessionId] = _SavedSessionReview(
          outputs: request.outputs,
          result: result,
          providerInfo: providerInfo,
          isPersisted: isPersisted,
        );
        _reviewErrors.remove(session.sessionId);
        if (isPersisted) _reviewStorageNotice = null;
      });
    } catch (error) {
      if (!mounted) return;
      final message = error is SubtitlePostSessionGenerationException
          ? error.userMessage
          : '生成失败。请检查 Provider 设置或稍后重试。';
      setState(() => _reviewErrors[session.sessionId] = message);
    } finally {
      _reviewBusySessions.remove(session.sessionId);
      if (mounted) setState(() {});
    }
  }

  Future<void> _load({bool force = false}) async {
    if (!mounted ||
        _bulkDeletingSessions ||
        (!force && (_loading || _refreshing || _videoIndexLoading))) {
      return;
    }
    final generation = ++_loadGeneration;
    final appDataDirectory = widget.appDataDirectory;
    final videoScanCapacityAvailable =
        appDataDirectory == null ||
        _recordingIndexScans.hasVideoScanCapacity(appDataDirectory);
    final loadVideoIndex =
        appDataDirectory != null && videoScanCapacityAvailable;
    setState(() {
      // Only the first read replaces the page with a loading skeleton. Later
      // refreshes keep the last usable history visible and show progress inline.
      _loading = !_hasLoadedOnce;
      _refreshing = _hasLoadedOnce;
      _selectedSessionIds.clear();
      _audioMetadataLoading = appDataDirectory != null;
      _videoIndexLoading = loadVideoIndex;
      _error = null;
      if (!_hasLoadedOnce || loadVideoIndex) _videoIndexNotice = null;
      if (appDataDirectory != null && !videoScanCapacityAvailable) {
        _videoIndexNotice =
            '视频目录仍有两次扫描未结束，已暂停新扫描以避免占用累积。字幕和录音历史可继续使用；待扫描结束后再点页面顶部刷新读取视频历史。';
      }
    });
    try {
      final sessions = await widget.store.listSessions().timeout(
        _historyReadTimeout,
      );
      if (!mounted || generation != _loadGeneration) return;
      final corruptSessionCount =
          widget.store is SubtitleSessionStoreDiagnostics
          ? (widget.store as SubtitleSessionStoreDiagnostics)
                .corruptSessionCount
          : 0;
      setState(() {
        _sessions = sessions;
        _corruptSessionCount = corruptSessionCount;
        _hasLoadedOnce = true;
        _loading = false;
        _refreshing = false;
      });
      unawaited(
        _loadHistoryMetadata(
          sessions: sessions,
          appDataDirectory: appDataDirectory,
          generation: generation,
        ),
      );
      if (appDataDirectory != null && loadVideoIndex) {
        unawaited(_loadVideoRecordings(appDataDirectory, generation));
      }
    } catch (error) {
      if (!mounted) return;
      if (generation != _loadGeneration) return;
      setState(() {
        _error = '字幕历史读取失败：$error';
        _loading = false;
        _refreshing = false;
        _videoIndexLoading = false;
      });
    }
  }

  Future<void> _loadHistoryMetadata({
    required List<SubtitleSessionRecord> sessions,
    required Directory? appDataDirectory,
    required int generation,
  }) {
    final queuedLoad = _historyMetadataLoadTail
        .then((_) async {
          if (!mounted || generation != _loadGeneration) return;
          await _loadHistoryMetadataNow(
            sessions: sessions,
            appDataDirectory: appDataDirectory,
            generation: generation,
          );
        })
        .catchError((Object _) {
          if (!mounted || generation != _loadGeneration) return;
          setState(() {
            _audioMetadataLoading = false;
            _audioIndexNotice = '本机录音索引暂时无法读取；字幕历史仍可使用。';
            _reviewStorageNotice = '复盘历史暂时无法读取；字幕历史仍可使用。';
          });
        })
        .whenComplete(() {
          if (mounted && generation == _loadGeneration) {
            _releaseCompletedAudioRecordingIndexLoads();
          }
        });
    _historyMetadataLoadTail = queuedLoad;
    return queuedLoad;
  }

  Future<void> _loadHistoryMetadataNow({
    required List<SubtitleSessionRecord> sessions,
    required Directory? appDataDirectory,
    required int generation,
  }) async {
    final audioDirectories = <String, Directory?>{};
    var audioIndexNotice = '';
    var standaloneRecordings = <SubtitleAudioIndexedRecording>[];
    final sessionAudioRecordings =
        <String, List<SubtitleAudioIndexedRecording>>{};
    final restoredReviews = <String, _SavedSessionReview>{};
    var reviewStorageNotice = '';

    if (appDataDirectory != null) {
      for (
        var offset = 0;
        offset < sessions.length;
        offset += _metadataLookupBatchSize
      ) {
        final batch = sessions.skip(offset).take(_metadataLookupBatchSize);
        final resolvedDirectories = await Future.wait(
          batch.map((session) async {
            try {
              final directory =
                  await (widget.sessionAudioDirectoryResolverForTesting?.call(
                            appDataDirectory,
                            session.sessionId,
                          ) ??
                          SubtitleAudioSessionRecorder.sessionRecordingsDirectory(
                            appDataDirectory: appDataDirectory,
                            sessionId: session.sessionId,
                          ))
                      .timeout(_historyReadTimeout);
              return MapEntry<String, Directory?>(session.sessionId, directory);
            } on Object {
              return null;
            }
          }),
        );
        if (!mounted || generation != _loadGeneration) return;
        for (final entry in resolvedDirectories) {
          if (entry != null) audioDirectories[entry.key] = entry.value;
        }
      }

      if (!mounted || generation != _loadGeneration) return;
      final transcriptSessionIds = sessions
          .map((session) => session.sessionId)
          .toSet();
      try {
        final audioIndex = await _loadAudioRecordingIndex(appDataDirectory)
            .timeout(_historyReadTimeout);
        final indexedRecordings = audioIndex.recordings;
        if (audioIndex.truncated) {
          audioIndexNotice = '录音历史扫描达到安全上限，部分文件未显示；可打开本机录音目录查看全部文件。';
        }
        for (final recording in indexedRecordings) {
          if (transcriptSessionIds.contains(recording.sessionId)) {
            sessionAudioRecordings
                .putIfAbsent(recording.sessionId, () => [])
                .add(recording);
          }
        }
        standaloneRecordings = indexedRecordings
            .where(
              (recording) =>
                  !transcriptSessionIds.contains(recording.sessionId),
            )
            .toList(growable: false);
      } on TimeoutException {
        audioIndexNotice = '独立录音目录暂时无法读取；字幕历史仍可使用。';
      } on Object {
        audioIndexNotice = '独立录音目录暂时无法读取；字幕历史仍可使用。';
      }
    }

    // A slow audio scan may outlive the history generation that started it.
    // A superseded scan must not proceed into review cleanup or publication.
    if (!mounted || generation != _loadGeneration) return;

    try {
      final storedReviews = await widget.reviewStore.listReviews().timeout(
        _historyReadTimeout,
      );
      if (!mounted || generation != _loadGeneration) return;
      final reviewsBySession = <String, SubtitlePostSessionStoredReview>{
        for (final review in storedReviews) review.sessionId: review,
      };
      final staleReviewSessionIds = <String>{};
      for (final session in sessions) {
        final stored = reviewsBySession[session.sessionId];
        if (stored == null) continue;
        try {
          final request = _buildReviewRequest(session, stored.outputs);
          if (stored.inputDigest != subtitlePostSessionInputDigest(request)) {
            staleReviewSessionIds.add(session.sessionId);
            continue;
          }
          validateSubtitlePostSessionResult(request, stored.result);
          restoredReviews[session.sessionId] = _SavedSessionReview(
            outputs: stored.outputs,
            result: stored.result,
            providerInfo: stored.providerInfo,
            isPersisted: true,
          );
        } catch (_) {
          staleReviewSessionIds.add(session.sessionId);
        }
      }
      try {
        for (final sessionId in staleReviewSessionIds) {
          if (!mounted || generation != _loadGeneration) return;
          await widget.reviewStore.deleteReview(sessionId);
        }
        if (!mounted || generation != _loadGeneration) return;
        await widget.reviewStore.retainSessionIds(
          sessions.map((session) => session.sessionId).toSet(),
        );
      } catch (_) {
        reviewStorageNotice = '部分过期复盘记录未能清理；字幕历史仍可使用。';
      }
    } on Object {
      reviewStorageNotice = '复盘历史暂时无法读取；字幕历史仍可使用。';
    }

    if (!mounted || generation != _loadGeneration) return;
    setState(() {
      _audioRecordingDirectories
        ..clear()
        ..addAll(audioDirectories);
      _sessionAudioRecordings
        ..clear()
        ..addAll(sessionAudioRecordings);
      _audioMetadataLoading = false;
      _standaloneAudioRecordings = standaloneRecordings;
      _audioIndexNotice = audioIndexNotice.isEmpty ? null : audioIndexNotice;
      _reviews
        ..clear()
        ..addAll(restoredReviews);
      _reviewStorageNotice = reviewStorageNotice.isEmpty
          ? null
          : reviewStorageNotice;
    });
  }

  Future<SubtitleAudioRecordingIndexResult> _loadAudioRecordingIndex(
    Directory appDataDirectory,
  ) {
    final absolutePath = appDataDirectory.absolute.path;
    final key = Platform.isWindows ? absolutePath.toLowerCase() : absolutePath;
    final pending = _audioRecordingIndexLoads[key];
    if (pending != null) return pending;

    final load = _recordingIndexScans.loadAudio(appDataDirectory, () {
      final injectedLoader = widget.audioRecordingLoader;
      if (injectedLoader == null) {
        return SubtitleAudioSessionRecorder.listSavedRecordingsWithStatus(
          appDataDirectory: appDataDirectory,
        );
      }
      return injectedLoader(appDataDirectory).then(
        (recordings) => SubtitleAudioRecordingIndexResult(
          recordings: recordings,
          truncated: false,
        ),
      );
    });
    _audioRecordingIndexLoads[key] = load;
    final pendingLoads = _audioRecordingIndexLoads;
    final completedLoads = _completedAudioRecordingIndexLoads;
    void markCompletedLoad() {
      if (identical(pendingLoads[key], load)) {
        completedLoads.add(key);
      }
    }

    // Future.timeout stops waiting, but does not cancel the underlying scan.
    // Keep it registered through queued refreshes and release it once the
    // newest metadata generation has consumed the completion.
    unawaited(
      load.then<void>(
        (_) => markCompletedLoad(),
        onError: (Object _, StackTrace _) => markCompletedLoad(),
      ),
    );
    return load;
  }

  void _releaseCompletedAudioRecordingIndexLoads() {
    for (final key in _completedAudioRecordingIndexLoads) {
      _audioRecordingIndexLoads.remove(key);
    }
    _completedAudioRecordingIndexLoads.clear();
  }

  Future<void> _loadVideoRecordings(
    Directory appDataDirectory,
    int generation,
  ) async {
    Future<SubtitleVideoRecordingIndexResult>? indexLoad;
    try {
      indexLoad = _loadVideoRecordingIndex(appDataDirectory);
      final index = await indexLoad.timeout(_historyReadTimeout);
      if (!mounted || generation != _loadGeneration) return;
      final recordings = index.recordings;
      setState(() {
        _videoRecordings = recordings;
        _videoRecordingsBySession = _indexVideoRecordings(recordings);
        _videoIndexNotice = index.truncated
            ? '视频历史扫描达到安全上限，部分文件未显示；可打开本机视频目录查看全部文件。'
            : null;
        _videoIndexLoading = false;
      });
    } on TimeoutException {
      // A timed-out scan cannot be cancelled. Retire it for one explicit
      // replacement on the next refresh, while the registry caps concurrent
      // scans at two for this directory.
      final retryAvailable =
          indexLoad != null &&
          _recordingIndexScans.releaseTimedOutVideoScan(
            appDataDirectory,
            indexLoad,
          );
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _videoRecordings = const <SubtitleVideoRecordingEntry>[];
        _videoRecordingsBySession =
            const <String, List<SubtitleVideoRecordingEntry>>{};
        _videoIndexNotice = retryAvailable
            ? '本机视频录制目录读取超时；可刷新历史再试一次。字幕和音频历史仍可使用。'
            : '视频目录仍有两次扫描未结束，已暂停新扫描以避免占用累积。字幕和录音历史可继续使用；待扫描结束后再点页面顶部刷新读取视频历史。';
        _videoIndexLoading = false;
      });
    } on Object {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _videoRecordings = const <SubtitleVideoRecordingEntry>[];
        _videoRecordingsBySession =
            const <String, List<SubtitleVideoRecordingEntry>>{};
        _videoIndexNotice = '本机视频录制目录暂时无法读取；字幕和音频历史仍可使用。';
        _videoIndexLoading = false;
      });
    }
  }

  Future<SubtitleVideoRecordingIndexResult> _loadVideoRecordingIndex(
    Directory appDataDirectory,
  ) {
    return _recordingIndexScans.loadVideo(appDataDirectory, () {
      final injectedLoader = widget.videoRecordingLoader;
      if (injectedLoader == null) {
        return SubtitleVideoRecordingIndex.listWithStatus(
          appDataDirectory: appDataDirectory,
        );
      }
      return injectedLoader(appDataDirectory).then(
        (recordings) => SubtitleVideoRecordingIndexResult(
          recordings: recordings,
          truncated: false,
        ),
      );
    });
  }

  Future<void> _export(
    SubtitleSessionRecord session,
    SubtitleExportFormat format,
  ) async {
    if (!_busySessions.add(session.sessionId)) return;
    setState(() {});
    try {
      final extension = switch (format) {
        SubtitleExportFormat.srt => 'srt',
        SubtitleExportFormat.webVtt => 'vtt',
      };
      final document = switch (format) {
        SubtitleExportFormat.srt => _exporter.toSrt(
          session.sessionId,
          session.segments,
        ),
        SubtitleExportFormat.webVtt => _exporter.toWebVtt(
          session.sessionId,
          session.segments,
        ),
      };
      final location = await getSaveLocation(
        suggestedName: 'yixue-${_sessionFileDate(session)}.$extension',
        acceptedTypeGroups: [
          XTypeGroup(
            label: extension == 'srt' ? 'SubRip 字幕' : 'WebVTT 字幕',
            extensions: [extension],
          ),
        ],
      );
      if (location == null) return;
      await File(location.path).writeAsString(document.content, flush: true);
      if (mounted) _showMessage('字幕已导出到 ${location.path}');
    } catch (error) {
      if (mounted) _showMessage('导出失败：$error');
    } finally {
      _busySessions.remove(session.sessionId);
      if (mounted) setState(() {});
    }
  }

  Future<void> _delete(SubtitleSessionRecord session) async {
    if (_bulkDeletingSessions || _blockHistoryMutationDuringMediaPlayback()) {
      return;
    }
    if (_audioMetadataLoading) {
      _showMessage('正在检查本次录音，请稍后再删除会话。');
      return;
    }
    if (subtitleHistorySessionHasActiveAudioPlayback(
      session.sessionId,
      _busyAudioFiles,
    )) {
      _showMessage('请先关闭本会话正在播放的录音，再删除会话。');
      return;
    }
    final hadAudioWhenPrompted =
        _audioRecordingDirectories[session.sessionId] != null;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除这次字幕会话？'),
        content: Text(
          hadAudioWhenPrompted
              ? '删除后，本机保存的会话字幕、关联复盘和本会话采集音频将无法恢复。'
              : '删除后，本机保存的会话字幕和关联的会后复盘将无法恢复。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除会话'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    if (_audioMetadataLoading) {
      _showMessage('正在更新本次录音信息，请稍后重新删除会话。');
      return;
    }
    final hasAudio = _audioRecordingDirectories[session.sessionId] != null;
    if (hasAudio != hadAudioWhenPrompted) {
      _showMessage('本次录音信息刚刚更新，请重新确认删除会话。');
      return;
    }
    final mediaMutation = _tryAcquireMediaMutation(
      'delete-session:${session.sessionId}',
    );
    if (mediaMutation == null) return;
    try {
      final deleted = await widget.store.deleteSession(session.sessionId);
      if (!mounted) return;
      if (!deleted) {
        _showMessage('这条字幕记录已不存在');
        await _load(force: true);
        return;
      }
      var reviewCleanupFailed = false;
      var audioCleanupFailed = false;
      try {
        await widget.reviewStore.deleteReview(session.sessionId);
      } catch (_) {
        reviewCleanupFailed = true;
      }
      final appDataDirectory = widget.appDataDirectory;
      if (appDataDirectory != null && hasAudio) {
        try {
          await SubtitleAudioSessionRecorder.deleteSessionRecordings(
            appDataDirectory: appDataDirectory,
            sessionId: session.sessionId,
          );
        } on Object {
          audioCleanupFailed = true;
        }
      }
      if (!mounted) return;
      setState(() {
        _sessions = _sessions
            .where((item) => item.sessionId != session.sessionId)
            .toList(growable: false);
        _selectedSessionIds.remove(session.sessionId);
        _reviews.remove(session.sessionId);
        _reviewErrors.remove(session.sessionId);
        _audioRecordingDirectories.remove(session.sessionId);
        _sessionAudioRecordings.remove(session.sessionId);
        if (reviewCleanupFailed) {
          _reviewStorageNotice = '字幕会话已删除，但复盘文件清理失败；刷新历史时会再次尝试。';
        }
      });
      _showMessage(
        audioCleanupFailed
            ? '字幕会话已删除，但录音文件未能删除，请在录音目录中手动处理。'
            : reviewCleanupFailed
            ? '字幕会话与录音已删除，但复盘文件清理失败。'
            : '字幕会话、关联复盘与采集录音已删除。',
      );
    } catch (error) {
      if (mounted) _showMessage('删除失败：$error');
    } finally {
      mediaMutation.release();
    }
  }

  void _toggleSelectAllFilteredSessions() {
    if (_bulkDeletingSessions || _loading || _refreshing) return;
    final eligibleSessions = _bulkDeletableFilteredSessions;
    if (eligibleSessions.isEmpty) {
      _showMessage('当前筛选结果中没有可删除的字幕会话；活动、正在播放或处理中的会话会保留。');
      return;
    }
    final allSelected = eligibleSessions.every(
      (session) => _selectedSessionIds.contains(session.sessionId),
    );
    setState(() {
      if (allSelected) {
        _selectedSessionIds.clear();
      } else {
        _selectedSessionIds.addAll(
          eligibleSessions.map((session) => session.sessionId),
        );
      }
    });
  }

  Future<void> _deleteSelectedSessions() async {
    if (_bulkDeletingSessions ||
        _blockHistoryMutationDuringMediaPlayback() ||
        _loading ||
        _refreshing ||
        _audioMetadataLoading ||
        _selectedSessionIds.isEmpty) {
      return;
    }
    final selectedSessions = _filteredSessions
        .where((session) => _selectedSessionIds.contains(session.sessionId))
        .toList(growable: false);
    if (selectedSessions.isEmpty) {
      setState(_selectedSessionIds.clear);
      _showMessage('当前筛选结果已变化，请重新选择要删除的字幕会话。');
      return;
    }
    final deletableSessions = selectedSessions
        .where(_canBulkDeleteSession)
        .toList(growable: false);
    if (deletableSessions.length != selectedSessions.length) {
      final deletableIds = deletableSessions
          .map((session) => session.sessionId)
          .toSet();
      setState(() {
        _selectedSessionIds.removeWhere(
          (sessionId) => !deletableIds.contains(sessionId),
        );
      });
      _showMessage('活动、正在播放或处理中的会话已取消选择，请先停止或关闭相关操作。');
      return;
    }

    final audioCount = deletableSessions
        .where(
          (session) => _audioRecordingDirectories[session.sessionId] != null,
        )
        .length;
    final appDataDirectory = widget.appDataDirectory;
    final count = deletableSessions.length;
    final confirmationDetails = <String>[
      '将删除本机保存的字幕与关联复盘',
      if (audioCount > 0) '将同时删除 $audioCount 条会话的采集音频',
      if (appDataDirectory == null) '应用数据目录不可用，采集音频不会删除',
      '视频录制由独立记录管理，不会随本操作删除',
      '此操作无法撤销',
    ].join('。');
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除选中的 $count 条字幕会话？'),
        content: Text(confirmationDetails),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final nowDeletable = deletableSessions
        .where(_canBulkDeleteSession)
        .toList(growable: false);
    if (nowDeletable.length != count) {
      _showMessage('会话状态已变化，未执行批量删除；请刷新后重新选择。');
      return;
    }

    final mediaMutation = _tryAcquireMediaMutation(
      'delete-selected-sessions:${deletableSessions.map((session) => session.sessionId).join(',')}',
    );
    if (mediaMutation == null) return;

    setState(() => _bulkDeletingSessions = true);
    final deletedIds = <String>{};
    var failedCount = 0;
    var reviewCleanupFailed = false;
    var audioCleanupFailed = false;
    try {
      for (final session in deletableSessions) {
        final sessionId = session.sessionId;
        final hasAudio = _audioRecordingDirectories[sessionId] != null;
        try {
          final deleted = await widget.store.deleteSession(sessionId);
          if (!deleted) {
            failedCount++;
            continue;
          }
          deletedIds.add(sessionId);
          try {
            await widget.reviewStore.deleteReview(sessionId);
          } on Object {
            reviewCleanupFailed = true;
          }
          if (appDataDirectory != null && hasAudio) {
            try {
              await SubtitleAudioSessionRecorder.deleteSessionRecordings(
                appDataDirectory: appDataDirectory,
                sessionId: sessionId,
              );
            } on Object {
              audioCleanupFailed = true;
            }
          }
        } on Object {
          failedCount++;
        }
      }

      if (!mounted) return;
      setState(() {
        _sessions = _sessions
            .where((session) => !deletedIds.contains(session.sessionId))
            .toList(growable: false);
        _selectedSessionIds.removeAll(deletedIds);
        for (final sessionId in deletedIds) {
          _reviews.remove(sessionId);
          _reviewErrors.remove(sessionId);
          _audioRecordingDirectories.remove(sessionId);
          _sessionAudioRecordings.remove(sessionId);
        }
        _videoRecordingsBySession =
            Map<String, List<SubtitleVideoRecordingEntry>>.unmodifiable({
              for (final entry in _videoRecordingsBySession.entries)
                if (!deletedIds.contains(entry.key)) entry.key: entry.value,
            });
        if (reviewCleanupFailed) {
          _reviewStorageNotice = '字幕会话已删除，但部分复盘文件清理失败；刷新历史时会再次尝试。';
        }
      });

      if (deletedIds.isEmpty && failedCount > 0) {
        _showMessage('删除失败；字幕历史保持原样，请刷新后重试。');
        return;
      }
      final status = <String>[
        if (audioCleanupFailed) '部分采集音频未能删除，请检查录音目录',
        if (reviewCleanupFailed) '部分复盘文件未能清理，刷新历史时会重试',
        if (failedCount > 0) '$failedCount 条会话未删除，请刷新后重试',
      ];
      final String cleanupSummary;
      if (status.isNotEmpty) {
        cleanupSummary = status.join('；');
      } else if (appDataDirectory == null) {
        cleanupSummary = '关联复盘已清理，采集音频未更改';
      } else if (audioCount > 0) {
        cleanupSummary = '关联复盘与采集音频已清理';
      } else {
        cleanupSummary = '关联复盘已清理，未发现关联采集音频';
      }
      _showMessage('已删除 ${deletedIds.length} 条字幕会话。$cleanupSummary。视频录制未更改。');
    } finally {
      mediaMutation.release();
      if (mounted) setState(() => _bulkDeletingSessions = false);
    }
  }

  Future<void> _openAudioRecordingDirectory(
    SubtitleSessionRecord session,
  ) async {
    final appDataDirectory = widget.appDataDirectory;
    if (appDataDirectory == null) return;
    try {
      final directory =
          await SubtitleAudioSessionRecorder.sessionRecordingsDirectory(
            appDataDirectory: appDataDirectory,
            sessionId: session.sessionId,
          );
      if (directory == null) {
        if (mounted) _showMessage('这次会话没有找到采集音频文件。');
        await _load(force: true);
        return;
      }
      final command = Platform.isWindows ? 'explorer.exe' : 'open';
      await Process.start(command, <String>[
        directory.path,
      ], mode: ProcessStartMode.detached);
    } on Object {
      if (mounted) _showMessage('无法打开本会话的录音目录。');
    }
  }

  Future<void> _deleteAudioRecordings(SubtitleSessionRecord session) async {
    final appDataDirectory = widget.appDataDirectory;
    if (appDataDirectory == null) return;
    if (_blockHistoryMutationDuringMediaPlayback()) return;
    if (subtitleHistorySessionHasActiveAudioPlayback(
      session.sessionId,
      _busyAudioFiles,
    )) {
      _showMessage('请先关闭本会话正在播放的录音，再删除录音。');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除本次采集音频？'),
        content: const Text('只删除本地录音媒体，不会删除字幕或复盘。此操作无法撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除录音'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final mediaMutation = _tryAcquireMediaMutation(
      'delete-session-audio:${session.sessionId}',
    );
    if (mediaMutation == null) return;
    try {
      final deleted =
          await SubtitleAudioSessionRecorder.deleteSessionRecordings(
            appDataDirectory: appDataDirectory,
            sessionId: session.sessionId,
          );
      if (!mounted) return;
      _showMessage(deleted == 0 ? '没有找到可删除的录音文件。' : '本次采集音频已删除。');
      await _load(force: true);
    } on Object {
      if (mounted) _showMessage('录音文件可能正在使用，删除失败；字幕与复盘保持不变。');
    } finally {
      mediaMutation.release();
    }
  }

  String _standaloneRecordingKey(SubtitleAudioIndexedRecording recording) =>
      '${recording.sessionId}:${recording.recordingId}';

  String _audioPlaybackKey(
    SubtitleAudioIndexedRecording recording,
    SubtitleAudioIndexedFile recordingFile,
  ) =>
      '${recording.sessionId}:${recording.recordingId}:${recordingFile.file.path}';

  Future<SubtitleAudioIndexedRecording?> _resolveStandaloneRecording(
    SubtitleAudioIndexedRecording recording,
  ) async {
    final appDataDirectory = widget.appDataDirectory;
    if (appDataDirectory == null) return null;
    final injectedResolver = widget.audioRecordingResolverForTesting;
    if (injectedResolver != null) {
      return injectedResolver(appDataDirectory, recording);
    }
    final latest = await SubtitleAudioSessionRecorder.listSavedRecordings(
      appDataDirectory: appDataDirectory,
    );
    for (final candidate in latest) {
      if (candidate.sessionId == recording.sessionId &&
          candidate.recordingId == recording.recordingId) {
        return candidate;
      }
    }
    return null;
  }

  Future<void> _openAudioRecordingFile(
    SubtitleAudioIndexedRecording recording,
    SubtitleAudioIndexedFile recordingFile,
  ) async {
    final playbackKey = _audioPlaybackKey(recording, recordingFile);
    if (_activeMediaPlaybackKey != null || _mediaPlaybackCoordinator.isBusy) {
      if (mounted) _showMediaBusyMessageForOpen();
      return;
    }
    if (!_busyAudioFiles.add(playbackKey)) return;
    final mediaKey = 'audio:$playbackKey';
    _activeMediaPlaybackKey = mediaKey;
    final lease = _mediaPlaybackCoordinator.tryAcquire(
      mediaKey,
      onReleased: () {
        _busyAudioFiles.remove(playbackKey);
        if (_activeMediaPlaybackKey == mediaKey) {
          _activeMediaPlaybackKey = null;
        }
        if (mounted) setState(() {});
      },
    );
    if (lease == null) {
      _busyAudioFiles.remove(playbackKey);
      _activeMediaPlaybackKey = null;
      if (mounted) {
        setState(() {});
        _showMessage('另一个播放器仍在释放资源，请稍后再试。');
      }
      return;
    }
    var dialogDisposedReported = false;
    var systemPlayerHandoffRequested = false;
    File? systemPlayerFile;
    if (mounted) setState(() {});
    try {
      // Never launch a path from an old UI snapshot. The index validates the
      // manifest and WAV again before the operating system receives a path.
      final current = await _resolveStandaloneRecording(recording);
      if (current == null) {
        if (mounted) _showMessage('这条录音已不存在或未通过文件校验，请刷新历史。');
        await _load(force: true);
        return;
      }
      SubtitleAudioIndexedFile? currentFile;
      for (final candidate in current.files) {
        if (candidate.file.path == recordingFile.file.path &&
            candidate.sourceKind == recordingFile.sourceKind) {
          currentFile = candidate;
          break;
        }
      }
      final playableFile = currentFile;
      if (playableFile == null ||
          await FileSystemEntity.type(
                playableFile.file.path,
                followLinks: false,
              ) !=
              FileSystemEntityType.file ||
          await playableFile.file.length() !=
              playableFile.dataBytes + playableFile.headerBytes) {
        if (mounted) _showMessage('这个 WAV 文件已变化或无法读取，请刷新历史。');
        await _load(force: true);
        return;
      }
      systemPlayerFile = playableFile.file;
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => RecordingMediaPlayerDialog(
          file: playableFile.file,
          title: '录音 · ${_sourceLabel(playableFile.sourceKind)}',
          // Open recordings in the bounded in-app player by default. If the
          // decoder fails, the dialog offers Windows' associated player as an
          // explicit fallback instead of sending users to a blank full-screen
          // surface without playback state.
          preferExternalPlayer:
              widget.preferExternalRecordingPlayerForTesting ?? false,
          controllerFactory:
              widget.recordingPlaybackControllerFactoryForTesting,
          details:
              '${playableFile.sampleRateHz} Hz · ${playableFile.channelCount} 声道 · ${_formatByteCount(playableFile.dataBytes + playableFile.headerBytes)}',
          onDialogDisposed: (pendingClose) {
            dialogDisposedReported = true;
            lease.reportDialogDisposed(pendingClose);
          },
          onSystemPlayerHandoffRequested: () =>
              systemPlayerHandoffRequested = true,
        ),
      );
    } on Object {
      if (mounted) _showMessage('无法在译学内打开这条录音；文件仍保留在本机。');
    } finally {
      if (!dialogDisposedReported) lease.reportDialogDisposed(null);
      lease.reportRouteClosed();
    }
    final handoffFile = systemPlayerFile;
    if (systemPlayerHandoffRequested && handoffFile != null) {
      await _openSystemPlayerAfterLeaseRelease(lease: lease, file: handoffFile);
    }
  }

  Future<void> _openSystemPlayerAfterLeaseRelease({
    required SubtitleMediaPlaybackLease lease,
    required File file,
  }) async {
    await lease.whenReleased;
    final launcher =
        widget.recordingSystemPlayerLauncherForTesting ??
        launchRecordingWithSystemPlayer;
    try {
      await launcher(file);
      if (mounted) _showMessage('已请求系统播放器打开录制文件；请确认播放正常。');
    } on Object catch (error) {
      if (mounted) _showMessage('系统播放器启动失败：$error。录制文件已保留在本机。');
    }
  }

  Future<void> _recoverAudioRecording(
    SubtitleAudioIndexedRecording recording,
    SubtitleAudioRecoveryCandidate recoveryCandidate,
  ) async {
    final key = _standaloneRecordingKey(recording);
    if (!_busyStandaloneRecordings.add(key)) return;
    if (mounted) setState(() {});
    try {
      final latest = await _resolveStandaloneRecording(recording);
      if (latest == null) {
        if (mounted) _showMessage('这条未完成录音已不存在，请刷新历史。');
        await _load(force: true);
        return;
      }
      SubtitleAudioRecoveryCandidate? currentCandidate;
      for (final candidate in latest.recoveryCandidates) {
        if (candidate.sourceId == recoveryCandidate.sourceId &&
            candidate.sourceKind == recoveryCandidate.sourceKind &&
            candidate.rawFile.path == recoveryCandidate.rawFile.path &&
            candidate.dataBytes == recoveryCandidate.dataBytes &&
            candidate.legacyMultichannelUpgrade ==
                recoveryCandidate.legacyMultichannelUpgrade) {
          currentCandidate = candidate;
          break;
        }
      }
      if (currentCandidate == null) {
        if (mounted) _showMessage('录音文件已变化，请刷新历史后再试。');
        await _load(force: true);
        return;
      }
      if (currentCandidate.dataBytes <= 0) {
        if (mounted) _showMessage('这条录音没有留下可恢复的音频数据。');
        return;
      }
      if (!mounted) return;
      final format = await showDialog<_AudioRecoveryFormat>(
        context: context,
        builder: (_) =>
            _AudioRecoveryFormatDialog(candidate: currentCandidate!),
      );
      if (format == null || !mounted) return;
      final appDataDirectory = widget.appDataDirectory;
      if (appDataDirectory == null) return;
      final mediaMutation = _tryAcquireMediaMutation(
        'recover-recording:${latest.sessionId}:${latest.recordingId}',
      );
      if (mediaMutation == null) return;
      late final String recoveredId;
      try {
        recoveredId =
            await SubtitleAudioSessionRecorder.recoverInterruptedRecording(
              appDataDirectory: appDataDirectory,
              sessionId: latest.sessionId,
              recordingId: latest.recordingId,
              sourceId: currentCandidate.sourceId,
              sourceKind: currentCandidate.sourceKind,
              sampleRateHz: format.sampleRateHz,
              channelCount: format.channelCount,
              upgradeLegacyMultichannel:
                  currentCandidate.legacyMultichannelUpgrade,
            );
      } finally {
        mediaMutation.release();
      }
      await _load(force: true);
      final recoveredRecordings =
          await SubtitleAudioSessionRecorder.listSavedRecordings(
            appDataDirectory: appDataDirectory,
          );
      SubtitleAudioIndexedRecording? recoveredRecording;
      for (final item in recoveredRecordings) {
        if (item.recordingId == recoveredId && item.files.isNotEmpty) {
          recoveredRecording = item;
          break;
        }
      }
      final playableCopy = recoveredRecording;
      if (mounted && playableCopy != null) {
        _showMessage(
          currentCandidate.legacyMultichannelUpgrade
              ? '旧版多声道录音已生成兼容副本，正在译学内打开；原文件仍保留。'
              : '旧录音已恢复成 WAV 副本，正在译学内打开；原文件仍保留。',
        );
        await _openAudioRecordingFile(playableCopy, playableCopy.files.first);
      } else if (mounted) {
        _showMessage('已创建恢复副本（$recoveredId），但暂时无法校验播放；原始未完成文件仍保留。');
      }
    } on FormatException catch (error) {
      if (mounted) _showMessage('无法恢复这条录音：${error.message}');
    } on StateError catch (error) {
      if (mounted) _showMessage(error.message.toString());
    } on Object {
      if (mounted) _showMessage('恢复失败；原始未完成文件仍保留。');
    } finally {
      _busyStandaloneRecordings.remove(key);
      if (mounted) setState(() {});
    }
  }

  Future<void> _openStandaloneRecordingFolder(
    SubtitleAudioIndexedRecording recording,
  ) async {
    try {
      final resolved = await _resolveStandaloneRecording(recording);
      if (resolved == null) {
        if (mounted) _showMessage('这条独立录音已不存在或文件校验失败。');
        await _load(force: true);
        return;
      }
      final command = Platform.isWindows ? 'explorer.exe' : 'open';
      await Process.start(command, <String>[
        resolved.directory.path,
      ], mode: ProcessStartMode.detached);
    } on Object {
      if (mounted) _showMessage('无法打开这条独立录音的目录。');
    }
  }

  Future<void> _deleteStandaloneRecording(
    SubtitleAudioIndexedRecording recording,
  ) async {
    final key = _standaloneRecordingKey(recording);
    if (_blockHistoryMutationDuringMediaPlayback()) return;
    if (subtitleHistoryRecordingHasActiveAudioPlayback(
      recording.sessionId,
      recording.recordingId,
      _busyAudioFiles,
    )) {
      if (mounted) _showMessage('请先关闭正在播放的录音，再删除这条记录。');
      return;
    }
    if (!_busyStandaloneRecordings.add(key)) return;
    if (mounted) setState(() {});
    try {
      final latest = await _resolveStandaloneRecording(recording);
      if (latest == null) {
        if (mounted) _showMessage('这条独立录音已不存在或文件校验失败。');
        await _load(force: true);
        return;
      }
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('删除这条仅录音记录？'),
          content: Text(
            '只删除本机这条录音中的 ${latest.files.length} 个 WAV 文件，不会修改其他录音或字幕历史。此操作无法撤销。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('删除录音'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      final mediaMutation = _tryAcquireMediaMutation(
        'delete-recording:${recording.sessionId}:${recording.recordingId}',
      );
      if (mediaMutation == null) return;
      final appDataDirectory = widget.appDataDirectory;
      try {
        if (appDataDirectory == null) return;
        final deleted = await SubtitleAudioSessionRecorder.deleteRecording(
          appDataDirectory: appDataDirectory,
          sessionId: latest.sessionId,
          recordingId: latest.recordingId,
        );
        if (!mounted) return;
        _showMessage(deleted == 0 ? '录音已不存在。' : '这条独立录音已删除。');
      } finally {
        mediaMutation.release();
      }
      await _load(force: true);
    } on StateError {
      if (mounted) _showMessage('这条录音含有未完成音源；请先恢复副本，再删除录音。');
    } on Object {
      if (mounted) _showMessage('录音可能正在写入或被其他进程占用，删除失败；字幕历史未更改。');
    } finally {
      _busyStandaloneRecordings.remove(key);
      if (mounted) setState(() {});
    }
  }

  Future<void> _openVideoRecording(
    SubtitleVideoRecordingEntry recording,
  ) async {
    if (recording.isIncomplete && _videoRecordingHasActiveSession(recording)) {
      _showMessage('关联会话仍在录制。请先停止录屏，结束后再播放这条未完成文件。');
      return;
    }
    if (_activeMediaPlaybackKey != null || _mediaPlaybackCoordinator.isBusy) {
      if (mounted) _showMediaBusyMessageForOpen();
      return;
    }
    if (!_busyVideoRecordings.add(recording.fileName)) return;
    final mediaKey = 'video:${recording.fileName}';
    _activeMediaPlaybackKey = mediaKey;
    final lease = _mediaPlaybackCoordinator.tryAcquire(
      mediaKey,
      onReleased: () {
        _busyVideoRecordings.remove(recording.fileName);
        if (_activeMediaPlaybackKey == mediaKey) {
          _activeMediaPlaybackKey = null;
        }
        if (mounted) setState(() {});
      },
    );
    if (lease == null) {
      _busyVideoRecordings.remove(recording.fileName);
      _activeMediaPlaybackKey = null;
      if (mounted) {
        setState(() {});
        _showMessage('另一个播放器仍在释放资源，请稍后再试。');
      }
      return;
    }
    var dialogDisposedReported = false;
    var systemPlayerHandoffRequested = false;
    File? systemPlayerFile;
    if (mounted) setState(() {});
    final appDataDirectory = widget.appDataDirectory;
    try {
      if (appDataDirectory == null) return;
      if (recording.isIncomplete &&
          await _videoRecordingSessionIsActiveNow(recording)) {
        if (mounted) {
          _showMessage('关联会话仍在录制。未完成录屏已保留，请先停止录制再播放。');
        }
        return;
      }
      final injectedResolver = widget.videoPlayableRecordingResolverForTesting;
      final file = injectedResolver == null
          ? await SubtitleVideoRecordingIndex.resolvePlayableRecording(
              appDataDirectory: appDataDirectory,
              fileName: recording.fileName,
            )
          : await injectedResolver(appDataDirectory, recording.fileName);
      if (file == null) {
        if (mounted) _showMessage('视频已不存在、录制未完成或媒体索引校验失败；请刷新历史。');
        await _load(force: true);
        return;
      }
      systemPlayerFile = file;
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => RecordingMediaPlayerDialog(
          file: file,
          title: '屏幕录制 · ${recording.fileName}',
          // Keep history playback inside this constrained dialog so users see
          // the first-frame loading state, decoder errors, and controls. The
          // system player remains available as a deliberate fallback.
          preferExternalPlayer:
              widget.preferExternalRecordingPlayerForTesting ?? false,
          controllerFactory:
              widget.recordingPlaybackControllerFactoryForTesting,
          details:
              '${_formatVideoDuration(recording.duration)} · ${_formatByteCount(recording.sizeBytes)}',
          onDialogDisposed: (pendingClose) {
            dialogDisposedReported = true;
            lease.reportDialogDisposed(pendingClose);
          },
          onSystemPlayerHandoffRequested: () =>
              systemPlayerHandoffRequested = true,
        ),
      );
    } on Object {
      if (mounted) _showMessage('无法在译学内打开这条视频；文件仍保留在本机。');
    } finally {
      if (!dialogDisposedReported) lease.reportDialogDisposed(null);
      lease.reportRouteClosed();
    }
    final handoffFile = systemPlayerFile;
    if (systemPlayerHandoffRequested && handoffFile != null) {
      await _openSystemPlayerAfterLeaseRelease(lease: lease, file: handoffFile);
    }
  }

  Future<void> _openVideoRecordingsFolder() async {
    final appDataDirectory = widget.appDataDirectory;
    if (appDataDirectory == null) return;
    try {
      final directory = await SubtitleVideoRecordingIndex.resolveDirectory(
        appDataDirectory: appDataDirectory,
      );
      if (directory == null) {
        if (mounted) _showMessage('视频录制目录不存在。');
        return;
      }
      final command = Platform.isWindows
          ? 'explorer.exe'
          : Platform.isMacOS
          ? 'open'
          : 'xdg-open';
      await Process.start(command, <String>[
        directory.path,
      ], mode: ProcessStartMode.detached);
    } on Object {
      if (mounted) _showMessage('无法打开本机视频录制目录。');
    }
  }

  bool _videoRecordingHasActiveSession(SubtitleVideoRecordingEntry recording) {
    final sessionId = recording.sessionId;
    if (sessionId == null || sessionId.isEmpty) return false;
    // Only the session lifecycle can say capture is still active. Audio index
    // statuses describe media completeness: `incomplete` can be a completed
    // WAV with dropped frames, and `unknown` means its loss counters are absent.
    // Neither status means the recorder still owns the associated video file.
    return _sessions.any(
      (session) =>
          session.sessionId == sessionId && _isActiveSession(session.status),
    );
  }

  Future<bool> _videoRecordingSessionIsActiveNow(
    SubtitleVideoRecordingEntry recording,
  ) async {
    if (_videoRecordingHasActiveSession(recording)) return true;
    final sessionId = recording.sessionId;
    if (sessionId == null || sessionId.isEmpty) return false;
    final latestSession = await widget.store.readSession(sessionId);
    return latestSession != null && _isActiveSession(latestSession.status);
  }

  Future<void> _deleteVideoRecording(
    SubtitleVideoRecordingEntry recording,
  ) async {
    if (_blockHistoryMutationDuringMediaPlayback()) return;
    if (recording.isIncomplete && _videoRecordingHasActiveSession(recording)) {
      _showMessage('关联会话仍在进行。请先停止录屏，结束后再处理这条未完成文件。');
      return;
    }
    if (!_busyVideoRecordings.add(recording.fileName)) return;
    if (mounted) setState(() {});
    SubtitleMediaMutationLease? mediaMutation;
    try {
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(recording.isIncomplete ? '处理未完成录屏' : '删除这段视频？'),
          content: Text(
            recording.isIncomplete
                ? '「${recording.fileName}」尚未完成，当前无法安全播放。可以保留原始文件供后续排查；译学暂不提供未完成 MP4 的修复操作。也可以只删除本机视频录制目录中的这一个文件，删除后无法恢复这段录屏。'
                : '将从本机视频录制目录删除「${recording.fileName}」（${_formatVideoDuration(recording.duration)}，${_formatByteCount(recording.sizeBytes)}）。此操作无法撤销。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(recording.isIncomplete ? '保留原文件' : '取消'),
            ),
            if (recording.isIncomplete)
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('稍后处理'),
              ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(recording.isIncomplete ? '确认删除并放弃恢复' : '删除视频'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      mediaMutation = _tryAcquireMediaMutation(
        'delete-video:${recording.fileName}',
      );
      if (mediaMutation == null) return;
      if (recording.isIncomplete &&
          await _videoRecordingSessionIsActiveNow(recording)) {
        if (mounted) {
          _showMessage('关联会话仍在进行。未完成录屏已保留，请先停止录制再处理。');
        }
        return;
      }
      final appDataDirectory = widget.appDataDirectory;
      if (appDataDirectory == null) return;
      final deleted = recording.isIncomplete
          ? await (widget.incompleteVideoDeleterForTesting?.call(
                  appDataDirectory,
                  recording.fileName,
                ) ??
                SubtitleVideoRecordingIndex.deleteIncompleteRecording(
                  appDataDirectory: appDataDirectory,
                  fileName: recording.fileName,
                ))
          : await SubtitleVideoRecordingIndex.deleteRecording(
              appDataDirectory: appDataDirectory,
              fileName: recording.fileName,
            );
      if (!mounted) return;
      _showMessage(
        deleted
            ? '本机视频已删除。'
            : recording.isIncomplete
            ? '文件刚有变化、仍太新或校验未通过，未删除；请先停止录制，再刷新历史重试。'
            : '视频已不存在或校验失败，未执行删除。',
      );
      await _load(force: true);
    } on Object {
      if (mounted) _showMessage('删除视频失败；其他录音和字幕历史未更改。');
    } finally {
      mediaMutation?.release();
      _busyVideoRecordings.remove(recording.fileName);
      if (mounted) setState(() {});
    }
  }

  Future<void> _pruneOlderSessions() async {
    if (_bulkDeletingSessions || _blockHistoryMutationDuringMediaPlayback()) {
      return;
    }
    if (_pruning) return;
    final selectedDays = await showDialog<int>(
      context: context,
      builder: (context) {
        var selected = 90;
        return StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: const Text('清理较早的字幕记录'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '这会删除期限以前已结束、已中断或失败的会话字幕、关联复盘和采集音频，无法撤销；仍在准备、采集或暂停中的会话会保留。',
                ),
                const SizedBox(height: 12),
                RadioGroup<int>(
                  groupValue: selected,
                  onChanged: (value) {
                    if (value != null) setDialogState(() => selected = value);
                  },
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final days in _retentionChoices)
                        RadioListTile<int>(
                          contentPadding: EdgeInsets.zero,
                          value: days,
                          title: Text('$days 天以前'),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, selected),
                child: const Text('删除较早记录'),
              ),
            ],
          ),
        );
      },
    );
    if (selectedDays == null || !mounted) return;
    final mediaMutation = _tryAcquireMediaMutation(
      'prune-sessions-before-${selectedDays}d',
    );
    if (mediaMutation == null) return;
    setState(() => _pruning = true);
    try {
      final cutoff = DateTime.now().toUtc().subtract(
        Duration(days: selectedDays),
      );
      final candidates = _sessions
          .where(
            (session) =>
                !_isActiveSession(session.status) &&
                session.startedAtUtc.isBefore(cutoff),
          )
          .toList(growable: false);
      final deleted = await widget.store.deleteSessionsBefore(cutoff);
      if (!mounted) return;
      var audioCleanupFailed = false;
      final appDataDirectory = widget.appDataDirectory;
      if (appDataDirectory != null) {
        for (final session in candidates) {
          try {
            await SubtitleAudioSessionRecorder.deleteSessionRecordings(
              appDataDirectory: appDataDirectory,
              sessionId: session.sessionId,
            );
          } on Object {
            audioCleanupFailed = true;
          }
        }
      }
      await _load(force: true);
      if (mounted) {
        _showMessage(
          audioCleanupFailed
              ? '已清理 $deleted 个较早字幕会话，但部分录音文件未能删除。'
              : '已清理 $deleted 个较早字幕会话及其关联录音。',
        );
      }
    } catch (error) {
      if (mounted) _showMessage('清理失败：$error');
    } finally {
      mediaMutation.release();
      if (mounted) setState(() => _pruning = false);
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape &&
        Navigator.of(context).canPop()) {
      unawaited(Navigator.of(context).maybePop());
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final filteredSessions = _filteredSessions;
    final deletableFilteredSessions = _bulkDeletableFilteredSessions;
    final allDeletableSessionsSelected =
        deletableFilteredSessions.isNotEmpty &&
        deletableFilteredSessions.every(
          (session) => _selectedSessionIds.contains(session.sessionId),
        );
    final visibleSessions = filteredSessions.take(_visibleSessionCount);
    final filteredStandaloneRecordings = _filteredStandaloneRecordings;
    final filteredVideoRecordings = _filteredVideoRecordings;
    final visibleStandaloneRecordings = filteredStandaloneRecordings
        .take(_visibleAudioRecordingCount)
        .toList(growable: false);
    final visibleVideoRecordings = filteredVideoRecordings
        .take(_visibleVideoRecordingCount)
        .toList(growable: false);
    return Focus(
      focusNode: _historyFocusNode,
      onKeyEvent: _handleKeyEvent,
      child: Scaffold(
        body: SafeArea(
          child: RefreshIndicator(
            onRefresh: _load,
            child: Scrollbar(
              controller: _historyScrollController,
              thumbVisibility: true,
              interactive: true,
              thickness: 12,
              radius: const Radius.circular(8),
              child: ScrollConfiguration(
                behavior: const MaterialScrollBehavior().copyWith(
                  dragDevices: const {
                    PointerDeviceKind.mouse,
                    PointerDeviceKind.touch,
                    PointerDeviceKind.stylus,
                    PointerDeviceKind.trackpad,
                  },
                ),
                child: ListView(
                  controller: _historyScrollController,
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(28, 24, 28, 36),
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        OutlinedButton.icon(
                          onPressed: () => Navigator.of(context).maybePop(),
                          icon: const Icon(Icons.arrow_back_rounded),
                          label: const Text('返回同传'),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'AI 同传 · 字幕历史',
                                style: Theme.of(context)
                                    .textTheme
                                    .headlineMedium
                                    ?.copyWith(fontWeight: FontWeight.w800),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                '查看已保存的原文与可用译文。导出为双语时间轴；尚未翻译的片段只包含原文。',
                                style: Theme.of(context).textTheme.bodyLarge
                                    ?.copyWith(color: colors.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: '刷新历史',
                          // A refresh must be able to supersede an in-flight
                          // history/metadata generation. `_loadGeneration`
                          // prevents the older read from publishing stale data.
                          onPressed: _bulkDeletingSessions
                              ? null
                              : () => _load(force: true),
                          icon: const Icon(Icons.refresh_rounded),
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton.icon(
                          onPressed:
                              _loading ||
                                  _refreshing ||
                                  _pruning ||
                                  _bulkDeletingSessions ||
                                  _sessions.isEmpty
                              ? null
                              : _pruneOlderSessions,
                          icon: const Icon(Icons.cleaning_services_outlined),
                          label: const Text('清理较早记录'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    _HistoryPrivacyNotice(colors: colors),
                    if (_corruptSessionCount > 0) ...[
                      const SizedBox(height: 10),
                      _CorruptSessionNotice(count: _corruptSessionCount),
                    ],
                    if (_reviewStorageNotice != null) ...[
                      const SizedBox(height: 10),
                      _ReviewStorageNotice(message: _reviewStorageNotice!),
                    ],
                    const SizedBox(height: 14),
                    TextField(
                      controller: _searchController,
                      enabled: !_bulkDeletingSessions,
                      onChanged: (value) => setState(() {
                        _searchQuery = value;
                        _selectedSessionIds.clear();
                        _visibleSessionCount = _sessionPageSize;
                        _resetVisibleMediaCounts();
                      }),
                      textInputAction: TextInputAction.search,
                      decoration: InputDecoration(
                        prefixIcon: const Icon(Icons.search_rounded),
                        labelText: '搜索视频文件名、录音、日期或字幕内容',
                        hintText: '可输入视频名、录音来源、日期、原文或译文',
                        border: const OutlineInputBorder(),
                        suffixIcon: _searchQuery.isEmpty
                            ? null
                            : IconButton(
                                tooltip: '清空搜索',
                                onPressed: () {
                                  _searchController.clear();
                                  setState(() {
                                    _searchQuery = '';
                                    _selectedSessionIds.clear();
                                    _visibleSessionCount = _sessionPageSize;
                                    _resetVisibleMediaCounts();
                                  });
                                },
                                icon: const Icon(Icons.close_rounded),
                              ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    if (_loading && !_hasLoadedOnce)
                      const _HistoryLoadingSkeleton()
                    else if (_error != null && _sessions.isEmpty)
                      _HistoryStateCard(
                        icon: Icons.error_outline_rounded,
                        title: '暂时无法读取字幕历史',
                        detail: _error!,
                        action: TextButton.icon(
                          onPressed: _load,
                          icon: const Icon(Icons.refresh_rounded),
                          label: const Text('重试'),
                        ),
                      )
                    else ...[
                      if (_refreshing) ...[
                        const LinearProgressIndicator(
                          key: ValueKey('subtitle-history-refresh-progress'),
                          minHeight: 2,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '正在刷新；现有记录仍可查看。',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: colors.onSurfaceVariant),
                        ),
                        const SizedBox(height: 10),
                      ],
                      if (_error != null && _sessions.isNotEmpty) ...[
                        _HistoryStateCard(
                          icon: Icons.warning_amber_rounded,
                          title: '刷新失败，保留上次读取的记录',
                          detail: _error!,
                          action: TextButton.icon(
                            onPressed: () => _load(force: true),
                            icon: const Icon(Icons.refresh_rounded),
                            label: const Text('重试'),
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],
                      if (_audioIndexNotice != null) ...[
                        _HistoryStateCard(
                          icon: Icons.warning_amber_rounded,
                          title: '本机录音历史提示',
                          detail: _audioIndexNotice!,
                          action: TextButton.icon(
                            onPressed: _load,
                            icon: const Icon(Icons.refresh_rounded),
                            label: const Text('重试'),
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],
                      if (_videoIndexNotice != null) ...[
                        _HistoryStateCard(
                          icon: Icons.warning_amber_rounded,
                          title: '本机视频历史提示',
                          detail: _videoIndexNotice!,
                          action:
                              widget.appDataDirectory == null ||
                                  _recordingIndexScans.hasVideoScanCapacity(
                                    widget.appDataDirectory!,
                                  )
                              ? TextButton.icon(
                                  onPressed: _load,
                                  icon: const Icon(Icons.refresh_rounded),
                                  label: const Text('重试'),
                                )
                              : null,
                        ),
                        const SizedBox(height: 12),
                      ],
                      if (_videoIndexLoading) ...[
                        const Row(
                          children: [
                            SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            SizedBox(width: 10),
                            Text('正在检查视频录制索引；字幕和录音历史已可查看。'),
                          ],
                        ),
                        const SizedBox(height: 12),
                      ],
                      if (filteredVideoRecordings.isNotEmpty) ...[
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '视频录制 · 显示 ${visibleVideoRecordings.length} / ${filteredVideoRecordings.length} 段',
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(fontWeight: FontWeight.w700),
                              ),
                            ),
                            TextButton.icon(
                              onPressed: _openVideoRecordingsFolder,
                              icon: const Icon(Icons.folder_open_outlined),
                              label: const Text('打开视频目录'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        for (final recording in visibleVideoRecordings)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: _VideoRecordingCard(
                              recording: recording,
                              busy:
                                  _bulkDeletingSessions ||
                                  _mediaPlaybackCoordinator.isBusy ||
                                  _busyVideoRecordings.contains(
                                    recording.fileName,
                                  ),
                              onOpenVideo: () => _openVideoRecording(recording),
                              onOpenFolder: _openVideoRecordingsFolder,
                              onDelete: () => _deleteVideoRecording(recording),
                            ),
                          ),
                        if (visibleVideoRecordings.length <
                            filteredVideoRecordings.length)
                          Align(
                            alignment: Alignment.centerLeft,
                            child: OutlinedButton.icon(
                              key: const ValueKey(
                                'subtitle-history-load-more-videos',
                              ),
                              onPressed: () => setState(() {
                                _visibleVideoRecordingCount += _mediaPageSize;
                              }),
                              icon: const Icon(Icons.expand_more_rounded),
                              label: const Text('加载更多录屏'),
                            ),
                          ),
                        const SizedBox(height: 10),
                      ],
                      if (filteredStandaloneRecordings.isNotEmpty) ...[
                        Text(
                          '仅录音 · 显示 ${visibleStandaloneRecordings.length} / ${filteredStandaloneRecordings.length} 条',
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 10),
                        for (final recording in visibleStandaloneRecordings)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: _StandaloneAudioRecordingCard(
                              recording: recording,
                              videoRecordings: _videoRecordingsForSession(
                                recording.sessionId,
                              ),
                              busyVideoRecordingFileNames: _busyVideoRecordings,
                              operationsLocked: _bulkDeletingSessions,
                              busyAudioPlaybackKeys: _busyAudioFiles,
                              audioPlaybackBusy:
                                  subtitleHistoryRecordingHasActiveAudioPlayback(
                                    recording.sessionId,
                                    recording.recordingId,
                                    _busyAudioFiles,
                                  ),
                              busy:
                                  _bulkDeletingSessions ||
                                  _mediaPlaybackCoordinator.isBusy ||
                                  _busyStandaloneRecordings.contains(
                                    _standaloneRecordingKey(recording),
                                  ),
                              onOpenFile: (file) =>
                                  _openAudioRecordingFile(recording, file),
                              onRecoverFile: (candidate) =>
                                  _recoverAudioRecording(recording, candidate),
                              onOpenFolder: () =>
                                  _openStandaloneRecordingFolder(recording),
                              onDelete: () =>
                                  _deleteStandaloneRecording(recording),
                              onOpenVideo: _openVideoRecording,
                              onDeleteVideo: _deleteVideoRecording,
                            ),
                          ),
                        if (visibleStandaloneRecordings.length <
                            filteredStandaloneRecordings.length)
                          Align(
                            alignment: Alignment.centerLeft,
                            child: OutlinedButton.icon(
                              key: const ValueKey(
                                'subtitle-history-load-more-audio',
                              ),
                              onPressed: () => setState(() {
                                _visibleAudioRecordingCount += _mediaPageSize;
                              }),
                              icon: const Icon(Icons.expand_more_rounded),
                              label: const Text('加载更多录音'),
                            ),
                          ),
                        const SizedBox(height: 10),
                      ],
                      if (_sessions.isEmpty)
                        _HistoryStateCard(
                          icon: Icons.subtitles_outlined,
                          title: '还没有保存的字幕会话',
                          detail: '停止并成功保存的字幕会话会显示在这里。独立录音可在上方单独打开和管理。',
                          action: OutlinedButton.icon(
                            onPressed: () => Navigator.of(context).maybePop(),
                            icon: const Icon(Icons.arrow_back_rounded),
                            label: const Text('返回同传工作台'),
                          ),
                        )
                      else if (filteredSessions.isEmpty)
                        _HistoryStateCard(
                          icon: Icons.search_off_rounded,
                          title: '没有匹配的字幕会话',
                          detail: '试试日期、原文或译文；独立录音也会按日期和音源参与搜索。',
                          action: TextButton.icon(
                            onPressed: () {
                              _searchController.clear();
                              setState(() {
                                _searchQuery = '';
                                _selectedSessionIds.clear();
                                _visibleSessionCount = _sessionPageSize;
                                _resetVisibleMediaCounts();
                              });
                            },
                            icon: const Icon(Icons.clear_rounded),
                            label: const Text('清空搜索'),
                          ),
                        )
                      else ...[
                        Text(
                          filteredSessions.length > visibleSessions.length
                              ? '显示 ${visibleSessions.length} / ${filteredSessions.length} 个字幕会话'
                              : _searchQuery.trim().isEmpty
                              ? '${filteredSessions.length} 个本地字幕会话'
                              : '找到 ${filteredSessions.length} 个字幕会话（共 ${_sessions.length} 个）',
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 10,
                          runSpacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            OutlinedButton.icon(
                              key: const ValueKey(
                                'subtitle-history-select-all',
                              ),
                              onPressed:
                                  _loading ||
                                      _refreshing ||
                                      _audioMetadataLoading ||
                                      _pruning ||
                                      _bulkDeletingSessions ||
                                      deletableFilteredSessions.isEmpty
                                  ? null
                                  : _toggleSelectAllFilteredSessions,
                              icon: Icon(
                                allDeletableSessionsSelected
                                    ? Icons.deselect_rounded
                                    : Icons.select_all_rounded,
                              ),
                              label: Text(
                                allDeletableSessionsSelected
                                    ? '清空已选'
                                    : '全选筛选结果',
                              ),
                            ),
                            if (_selectedSessionIds.isNotEmpty)
                              FilledButton.tonalIcon(
                                key: const ValueKey(
                                  'subtitle-history-delete-selected',
                                ),
                                onPressed:
                                    _bulkDeletingSessions ||
                                        _audioMetadataLoading ||
                                        _pruning
                                    ? null
                                    : _deleteSelectedSessions,
                                icon: _bulkDeletingSessions
                                    ? const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Icon(Icons.delete_outline_rounded),
                                label: Text(
                                  _bulkDeletingSessions
                                      ? '正在删除…'
                                      : '删除所选（${_selectedSessionIds.length}）',
                                ),
                              ),
                            if (_selectedSessionIds.isNotEmpty)
                              Text('${_selectedSessionIds.length} 条已选'),
                            if (_audioMetadataLoading)
                              const Text('正在检查会话录音…')
                            else if (deletableFilteredSessions.length <
                                filteredSessions.length)
                              const Text('活动、播放中或处理中会话会保留。'),
                          ],
                        ),
                        const SizedBox(height: 10),
                        for (final session in visibleSessions)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: _SessionCard(
                              session: session,
                              videoRecordings: _videoRecordingsForSession(
                                session.sessionId,
                              ),
                              videoIndexLoading: _videoIndexLoading,
                              videoIndexNotice: _videoIndexNotice,
                              busyVideoRecordingFileNames: _busyVideoRecordings,
                              busy:
                                  _busySessions.contains(session.sessionId) ||
                                  _mediaPlaybackCoordinator.isBusy,
                              audioMetadataLoading: _audioMetadataLoading,
                              reviewBusy: _reviewBusySessions.contains(
                                session.sessionId,
                              ),
                              reviewError: _reviewErrors[session.sessionId],
                              review: _reviews[session.sessionId],
                              hasAudioRecordings:
                                  _audioRecordingDirectories[session
                                      .sessionId] !=
                                  null,
                              audioRecordings:
                                  _sessionAudioRecordings[session.sessionId] ??
                                  const <SubtitleAudioIndexedRecording>[],
                              busyAudioPlaybackKeys: _busyAudioFiles,
                              audioPlaybackBusy:
                                  subtitleHistorySessionHasActiveAudioPlayback(
                                    session.sessionId,
                                    _busyAudioFiles,
                                  ),
                              operationsLocked: _bulkDeletingSessions,
                              generatorAvailable:
                                  widget.postSessionGenerator != null,
                              onExport: (format) => _export(session, format),
                              onDelete: () => _delete(session),
                              onOpenAudioRecordings: () =>
                                  _openAudioRecordingDirectory(session),
                              onOpenAudioFile: _openAudioRecordingFile,
                              onRecoverAudioFile: _recoverAudioRecording,
                              onDeleteAudioRecordings: () =>
                                  _deleteAudioRecordings(session),
                              onOpenVideo: _openVideoRecording,
                              onDeleteVideo: _deleteVideoRecording,
                              onGenerateReview: () => _generateReview(session),
                            ),
                          ),
                        if (visibleSessions.length < filteredSessions.length)
                          Padding(
                            padding: const EdgeInsets.only(top: 4, bottom: 12),
                            child: Center(
                              child: OutlinedButton.icon(
                                key: const ValueKey(
                                  'subtitle-history-load-more-sessions',
                                ),
                                onPressed: () => setState(
                                  () =>
                                      _visibleSessionCount += _sessionPageSize,
                                ),
                                icon: const Icon(Icons.expand_more_rounded),
                                label: const Text('加载更多会话'),
                              ),
                            ),
                          ),
                      ],
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _HistoryPrivacyNotice extends StatelessWidget {
  const _HistoryPrivacyNotice({required this.colors});

  final ColorScheme colors;

  @override
  Widget build(BuildContext context) => Material(
    color: colors.secondaryContainer.withValues(alpha: 0.46),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(14),
      side: BorderSide(color: colors.outlineVariant),
    ),
    clipBehavior: Clip.antiAlias,
    child: ExpansionTile(
      key: const ValueKey('subtitle-history-privacy-details'),
      initiallyExpanded: false,
      leading: Icon(
        Icons.info_outline_rounded,
        color: colors.onSecondaryContainer,
      ),
      title: const Text('数据如何保存'),
      subtitle: const Text(
        '字幕保存在本机；录音/录屏需开启，远程复盘确认后发送。',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      children: const [
        Text(
          '字幕会话和确认后的字幕文本保存在本机。开始同传时可选择系统播放声音和/或麦克风；每条字幕会标出实际音源，但音源类别不代表说话人身份。录音媒体由独立录制记录管理，不会从字幕历史自动读取。会后复盘按需运行；若选择远程 Provider，会先显示数据目的地和发送内容，并在你确认后发送字幕文本、来源标识与时间范围。',
        ),
      ],
    ),
  );
}

final class _CorruptSessionNotice extends StatelessWidget {
  const _CorruptSessionNotice({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.errorContainer.withValues(alpha: .35),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, color: colors.error),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '有 $count 条字幕记录的索引文件损坏，已跳过这些记录；原文件仍保留，其他历史可以继续使用。',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}

final class _SessionCard extends StatelessWidget {
  const _SessionCard({
    required this.session,
    required this.videoRecordings,
    required this.videoIndexLoading,
    required this.videoIndexNotice,
    required this.busyVideoRecordingFileNames,
    required this.busyAudioPlaybackKeys,
    required this.audioPlaybackBusy,
    required this.busy,
    required this.operationsLocked,
    required this.reviewBusy,
    required this.reviewError,
    required this.review,
    required this.generatorAvailable,
    required this.audioMetadataLoading,
    required this.hasAudioRecordings,
    required this.audioRecordings,
    required this.onExport,
    required this.onDelete,
    required this.onOpenAudioRecordings,
    required this.onOpenAudioFile,
    required this.onRecoverAudioFile,
    required this.onDeleteAudioRecordings,
    required this.onOpenVideo,
    required this.onDeleteVideo,
    required this.onGenerateReview,
  });

  final SubtitleSessionRecord session;
  final List<SubtitleVideoRecordingEntry> videoRecordings;
  final bool videoIndexLoading;
  final String? videoIndexNotice;
  final Set<String> busyVideoRecordingFileNames;
  final Set<String> busyAudioPlaybackKeys;
  final bool audioPlaybackBusy;
  final bool busy;
  final bool operationsLocked;
  final bool reviewBusy;
  final String? reviewError;
  final _SavedSessionReview? review;
  final bool generatorAvailable;
  final bool audioMetadataLoading;
  final bool hasAudioRecordings;
  final List<SubtitleAudioIndexedRecording> audioRecordings;
  final ValueChanged<SubtitleExportFormat> onExport;
  final VoidCallback onDelete;
  final VoidCallback onOpenAudioRecordings;
  final void Function(SubtitleAudioIndexedRecording, SubtitleAudioIndexedFile)
  onOpenAudioFile;
  final void Function(
    SubtitleAudioIndexedRecording,
    SubtitleAudioRecoveryCandidate,
  )
  onRecoverAudioFile;
  final VoidCallback onDeleteAudioRecordings;
  final ValueChanged<SubtitleVideoRecordingEntry> onOpenVideo;
  final ValueChanged<SubtitleVideoRecordingEntry> onDeleteVideo;
  final VoidCallback onGenerateReview;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final started = session.startedAtUtc.toLocal();
    final target = session.targetLanguageCode;
    final active = _isActiveSession(session.status);
    final operationBusy = busy || operationsLocked;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        key: PageStorageKey<String>('subtitle-session-${session.sessionId}'),
        tilePadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
        childrenPadding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
        leading: CircleAvatar(
          backgroundColor: colors.primaryContainer,
          foregroundColor: colors.onPrimaryContainer,
          child: Icon(_kindIcon(session.kind)),
        ),
        title: Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(_kindLabel(session.kind)),
            _SmallStatusChip(
              label: _sessionStatusLabel(session.status),
              color: _statusColor(context, session.status),
            ),
          ],
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 5),
          child: Text(
            '${_formatDate(started)}  ·  ${_sessionSourceSummary(session)}  ·  ${session.segments.length} 条字幕${target == null ? '' : '  ·  目标语种 $target'}${session.corruptSegmentCount == 0 ? '' : '  ·  已跳过 ${session.corruptSegmentCount} 条损坏字幕'}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (operationBusy)
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              PopupMenuButton<SubtitleExportFormat>(
                tooltip: '导出字幕',
                enabled: session.segments.isNotEmpty,
                onSelected: onExport,
                itemBuilder: (context) => const [
                  PopupMenuItem(
                    value: SubtitleExportFormat.srt,
                    child: Text('双语 SRT（未译片段保留原文）'),
                  ),
                  PopupMenuItem(
                    value: SubtitleExportFormat.webVtt,
                    child: Text('双语 WebVTT（未译片段保留原文）'),
                  ),
                ],
                icon: const Icon(Icons.download_outlined),
              ),
            IconButton(
              tooltip: audioMetadataLoading
                  ? '正在检查录音，请稍后删除会话'
                  : active
                  ? '请先停止活动会话，再删除'
                  : audioPlaybackBusy
                  ? '请先关闭本会话的录音播放器，再删除'
                  : '删除会话',
              onPressed:
                  operationBusy ||
                      reviewBusy ||
                      audioMetadataLoading ||
                      active ||
                      audioPlaybackBusy
                  ? null
                  : onDelete,
              icon: const Icon(Icons.delete_outline_rounded),
            ),
            const Icon(Icons.expand_more_rounded),
          ],
        ),
        children: [
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '场景类型：${_kindLabel(session.kind)}。本记录保存字幕、可选采集音频和按会话 ID 关联的录屏。'
                '旧版或无法关联的录屏会保留在历史页上方单独列出。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
          if (session.corruptSegmentCount > 0)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                '恢复时跳过了 ${session.corruptSegmentCount} 条损坏或无法读取的字幕文件，其余记录仍可查看。原文件保留在本机。',
                style: TextStyle(color: colors.error),
              ),
            ),
          if (session.segments.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 16),
              child: Text('这个会话没有已保存的字幕片段。'),
            )
          else
            _PaginatedSubtitleCueList(segments: session.segments),
          if (videoRecordings.isNotEmpty ||
              session.kind == SubtitleSessionKind.video) ...[
            const SizedBox(height: 20),
            const Divider(),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                children: [
                  Icon(
                    Icons.video_file_outlined,
                    color: colors.primary,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '本次会话录屏',
                    style: Theme.of(context).textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            if (videoRecordings.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    videoIndexLoading
                        ? '正在检查本次会话的录屏…'
                        : videoIndexNotice == null
                        ? '没有找到与本次会话关联的录屏。可能未开启录制，或文件已被移动或删除。'
                        : '目前无法确认本次会话的录屏。请先查看上方录屏索引提示，再刷新历史。',
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: colors.onSurfaceVariant),
                  ),
                ),
              )
            else
              for (final recording in videoRecordings)
                _SessionVideoRecordingTile(
                  recording: recording,
                  busy:
                      operationBusy ||
                      busyVideoRecordingFileNames.contains(recording.fileName),
                  onOpen: () => onOpenVideo(recording),
                  onDelete: () => onDeleteVideo(recording),
                ),
          ],
          const SizedBox(height: 20),
          const Divider(),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              children: [
                Icon(
                  Icons.audio_file_outlined,
                  color: colors.primary,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Text(
                  '采集音频',
                  style: Theme.of(context).textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            audioRecordings.any((recording) => recording.files.isNotEmpty)
                ? '本机会话录音与字幕分开保存。选择音源即可在译学内播放 WAV。'
                : audioRecordings.any(
                    (recording) => recording.recoveryCandidates.isNotEmpty,
                  )
                ? audioRecordings.any(
                        (recording) => recording.recoveryCandidates.any(
                          (candidate) => candidate.legacyMultichannelUpgrade,
                        ),
                      )
                      ? '发现旧版多声道录音，当前系统播放器可能无法识别。可以生成兼容副本并在译学内播放；原文件会保留。'
                      : '发现未完成录音。可以用保存的格式恢复，或为旧记录手动选择格式；恢复会生成副本并保留原始文件。'
                : audioRecordings.any(
                    (recording) => recording.emptyAudioSources > 0,
                  )
                ? '录音记录已保存，但没有采集到音频数据，因此没有可播放文件；字幕仍可查看和导出。'
                : hasAudioRecordings
                ? '找到了录音目录，但没有通过校验的可播放 WAV；字幕仍可查看和导出。'
                : '这次会话没有找到保存的录音；字幕仍可查看和导出。',
          ),
          for (final recording in audioRecordings)
            for (final recordingFile in recording.files)
              Builder(
                builder: (_) {
                  final isOpening = busyAudioPlaybackKeys.contains(
                    '${recording.sessionId}:${recording.recordingId}:${recordingFile.file.path}',
                  );
                  return ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: isOpening
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.play_circle_outline_rounded),
                    title: Text(
                      isOpening
                          ? '正在打开${_sourceLabel(recordingFile.sourceKind)}录音…'
                          : '播放${_sourceLabel(recordingFile.sourceKind)}',
                    ),
                    subtitle: Text(
                      '${_formatDate(recording.startedAtUtc.toLocal())} · ${_formatByteCount(recordingFile.dataBytes + recordingFile.headerBytes)}'
                      '${recording.status == SubtitleAudioIndexedRecordingStatus.incomplete ? ' · 有缺段' : ''}'
                      '${recording.status == SubtitleAudioIndexedRecordingStatus.interrupted ? ' · 已中断' : ''}',
                    ),
                    onTap: operationBusy || isOpening
                        ? null
                        : () => onOpenAudioFile(recording, recordingFile),
                  );
                },
              ),
          for (final recording in audioRecordings)
            for (final candidate in recording.recoveryCandidates)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.restore_rounded),
                title: Text(
                  candidate.legacyMultichannelUpgrade
                      ? '修复并播放旧版多声道${_sourceLabel(candidate.sourceKind)}录音'
                      : '恢复并播放${_sourceLabel(candidate.sourceKind)}录音',
                ),
                subtitle: Text(
                  candidate.legacyMultichannelUpgrade
                      ? '${_formatByteCount(candidate.dataBytes)} · ${candidate.sampleRateHz} Hz · ${candidate.channelCount} 声道 · 将改写为兼容 WAV 副本，原文件保留'
                      : '${_formatByteCount(candidate.dataBytes)} PCM 数据'
                            '${candidate.formatKnown ? ' · ${candidate.sampleRateHz} Hz · ${candidate.channelCount} 声道' : ' · 原记录缺少音频格式；选择格式后在译学内试听'}'
                            ' · 请勿直接用系统播放器打开未完成原文件',
                ),
                trailing: TextButton(
                  onPressed: !operationBusy && candidate.dataBytes > 0
                      ? () => onRecoverAudioFile(recording, candidate)
                      : null,
                  child: Text(
                    candidate.legacyMultichannelUpgrade ? '创建兼容副本' : '恢复并播放',
                  ),
                ),
              ),
          if (hasAudioRecordings) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: operationBusy ? null : onOpenAudioRecordings,
                  icon: const Icon(Icons.folder_open_outlined),
                  label: const Text('打开录音目录'),
                ),
                OutlinedButton.icon(
                  onPressed: operationBusy || active || audioPlaybackBusy
                      ? null
                      : onDeleteAudioRecordings,
                  icon: const Icon(Icons.delete_outline_rounded),
                  label: const Text('删除录音'),
                ),
              ],
            ),
          ],
          const SizedBox(height: 20),
          const Divider(),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              children: [
                Icon(
                  Icons.auto_awesome_outlined,
                  color: colors.primary,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Text(
                  '会后复盘',
                  style: Theme.of(context).textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          const Text('仅基于本机已保存的确认字幕按需生成；每条结果都必须关联到来源片段和时间范围。'),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonalIcon(
              onPressed:
                  !generatorAvailable ||
                      operationsLocked ||
                      reviewBusy ||
                      active ||
                      session.segments.isEmpty
                  ? null
                  : onGenerateReview,
              icon: reviewBusy
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.summarize_outlined),
              label: Text(
                reviewBusy
                    ? '正在生成…'
                    : review == null
                    ? '生成摘要、术语表或行动项'
                    : '重新生成会后复盘',
              ),
            ),
          ),
          if (!generatorAvailable) ...[
            const SizedBox(height: 6),
            Text(
              '尚未配置可用的“理解与总结”Provider；可先在“模型与服务”中启用一个。',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: colors.onSurfaceVariant),
            ),
          ] else if (active) ...[
            const SizedBox(height: 6),
            Text(
              '请先停止并保存此会话，再生成复盘。',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: colors.onSurfaceVariant),
            ),
          ],
          if (reviewError != null) ...[
            const SizedBox(height: 10),
            _HistoryStateCard(
              icon: Icons.error_outline_rounded,
              title: '复盘生成失败，字幕历史未变更',
              detail: reviewError!,
              action: TextButton.icon(
                onPressed: reviewBusy ? null : onGenerateReview,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('重试'),
              ),
            ),
          ],
          if (review != null) ...[
            const SizedBox(height: 14),
            _PostSessionReviewView(review: review!),
          ],
        ],
      ),
    );
  }
}

final class _SessionVideoRecordingTile extends StatelessWidget {
  const _SessionVideoRecordingTile({
    required this.recording,
    required this.busy,
    required this.onOpen,
    required this.onDelete,
  });

  final SubtitleVideoRecordingEntry recording;
  final bool busy;
  final VoidCallback onOpen;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final isEmpty = recording.sizeBytes == 0;
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.video_file_outlined),
      title: Text(
        recording.fileName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        recording.isIncomplete
            ? isEmpty
                  ? '录屏文件为空（0 B），没有可播放的视频数据'
                  : recording.canAttemptPlayback
                  ? '录屏未完成 · 可尝试播放；不可修复时可保留原文件或删除'
                  : '录屏未完成 · 无法安全播放；可保留原文件或删除'
            : '${_formatVideoDuration(recording.duration)} · '
                  '${_formatByteCount(recording.sizeBytes)} · '
                  '${_formatDate(recording.modifiedAt.toLocal())}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Wrap(
        spacing: 0,
        children: [
          IconButton(
            tooltip: recording.isIncomplete
                ? isEmpty
                      ? '文件没有视频数据，无法播放'
                      : recording.canAttemptPlayback
                      ? '尝试播放未完成录屏'
                      : '录屏未完成，无法安全播放'
                : '播放本次录屏',
            onPressed:
                busy ||
                    (recording.isIncomplete && !recording.canAttemptPlayback)
                ? null
                : onOpen,
            icon: busy
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.play_circle_outline_rounded),
          ),
          IconButton(
            tooltip: recording.isIncomplete ? '处理未完成录屏：保留原文件或确认删除' : '删除这段录屏',
            onPressed: busy ? null : onDelete,
            icon: Icon(
              recording.isIncomplete
                  ? Icons.delete_sweep_outlined
                  : Icons.delete_outline_rounded,
            ),
          ),
        ],
      ),
    );
  }
}

final class _SubtitleCueTile extends StatelessWidget {
  const _SubtitleCueTile({required this.index, required this.segment});

  final int index;
  final SubtitleSegment segment;

  @override
  Widget build(BuildContext context) {
    final transcript = segment.transcript;
    final translated =
        segment.translationStatus == SubtitleTranslationStatus.translated;
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 124,
            child: Text(
              '${_formatTimestamp(transcript.startMs)}\n${_sourceLabel(transcript.sourceKind)}\n${_transcriptLanguageLabel(transcript.languageCode)}\n${_translationStatusLabel(segment.translationStatus)}',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Tooltip(
                  message: '音源 ID：${transcript.sourceId}',
                  child: Text(
                    '来源 ID：${_shortenId(transcript.sourceId)}',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(height: 3),
                SelectableText(
                  key: PageStorageKey<String>(
                    'subtitle-history-source-${transcript.segmentId}',
                  ),
                  '${index.toString().padLeft(2, '0')}  ${formatSubtitleTextForDisplay(transcript.text, languageCode: transcript.languageCode)}',
                ),
                if (translated && segment.translatedText != null) ...[
                  const SizedBox(height: 5),
                  SelectableText(
                    key: PageStorageKey<String>(
                      'subtitle-history-translation-${transcript.segmentId}',
                    ),
                    segment.translatedText!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

final class _PaginatedSubtitleCueList extends StatefulWidget {
  const _PaginatedSubtitleCueList({required this.segments});

  final List<SubtitleSegment> segments;

  @override
  State<_PaginatedSubtitleCueList> createState() =>
      _PaginatedSubtitleCueListState();
}

final class _PaginatedSubtitleCueListState
    extends State<_PaginatedSubtitleCueList> {
  static const _batchSize = 40;
  var _visibleCount = _batchSize;

  @override
  Widget build(BuildContext context) {
    final visibleCount = widget.segments.length < _visibleCount
        ? widget.segments.length
        : _visibleCount;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var index = 0; index < visibleCount; index += 1)
          _SubtitleCueTile(index: index + 1, segment: widget.segments[index]),
        if (visibleCount < widget.segments.length)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                key: const ValueKey('subtitle-history-load-more-cues'),
                onPressed: () => setState(() => _visibleCount += _batchSize),
                icon: const Icon(Icons.expand_more_rounded),
                label: const Text('继续加载字幕'),
              ),
            ),
          ),
      ],
    );
  }
}

final class _SavedSessionReview {
  const _SavedSessionReview({
    required this.outputs,
    required this.result,
    required this.providerInfo,
    required this.isPersisted,
  });

  final Set<SubtitlePostSessionOutputKind> outputs;
  final SubtitlePostSessionResult result;
  final SubtitlePostSessionProviderInfo providerInfo;
  final bool isPersisted;
}

final class _ReviewStorageNotice extends StatelessWidget {
  const _ReviewStorageNotice({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: colors.errorContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, color: colors.onErrorContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: colors.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }
}

final class _ReviewPrivacyNotice extends StatelessWidget {
  const _ReviewPrivacyNotice({
    required this.providerInfo,
    required this.segmentCount,
  });

  final SubtitlePostSessionProviderInfo providerInfo;
  final int segmentCount;

  @override
  Widget build(BuildContext context) {
    final remote = providerInfo.kind == SubtitlePostSessionProviderKind.remote;
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: (remote ? colors.tertiaryContainer : colors.secondaryContainer)
            .withValues(alpha: 0.42),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Text(
        remote
            ? '确认后将向 ${providerInfo.processingDestination} 发送本次 $segmentCount 条已保存字幕的原文、可用译文、来源类别与来源 ID、片段 ID 和会话时间范围。不会发送原始音频、视频或本地媒体路径。'
            : '本次复盘由 ${providerInfo.processingDestination} 处理，只读取已保存确认字幕及其来源/时间信息；不会更改字幕，也不会读取原始音频或视频。',
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: remote
              ? colors.onTertiaryContainer
              : colors.onSecondaryContainer,
        ),
      ),
    );
  }
}

final class _PostSessionReviewView extends StatelessWidget {
  const _PostSessionReviewView({required this.review});

  final _SavedSessionReview review;

  @override
  Widget build(BuildContext context) {
    final result = review.result;
    final generatedAt = result.generatedAtUtc.toLocal();
    final timestamp = _formatDate(generatedAt);
    return Card(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '本次复盘 · $timestamp',
              style: Theme.of(context).textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              '处理位置：${review.providerInfo.processingDestination} · '
              '${review.isPersisted ? '已保存在本机复盘历史' : '本次未能保存，关闭页面后会丢失'}；字幕历史保持原样。',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            if (review.outputs.contains(SubtitlePostSessionOutputKind.summary))
              _buildSection<SubtitlePostSessionInsight>(
                context,
                title: '摘要',
                emptyLabel: '模型没有生成摘要条目。',
                items: result.summaryPoints,
                buildItem: (item) => Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SelectableText(item.text),
                    const SizedBox(height: 6),
                    _ReviewSourceReferences(sources: item.sources),
                  ],
                ),
              ),
            if (review.outputs.contains(
              SubtitlePostSessionOutputKind.terminology,
            ))
              _buildSection<SubtitlePostSessionTerm>(
                context,
                title: '术语表',
                emptyLabel: '模型没有提取到术语。',
                items: result.terms,
                buildItem: (item) => Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text.rich(
                      TextSpan(
                        style: Theme.of(context).textTheme.bodyMedium,
                        children: [
                          TextSpan(
                            text: '${item.term}  ',
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          TextSpan(text: item.explanation),
                        ],
                      ),
                    ),
                    const SizedBox(height: 6),
                    _ReviewSourceReferences(sources: item.sources),
                  ],
                ),
              ),
            if (review.outputs.contains(
              SubtitlePostSessionOutputKind.actionItems,
            ))
              _buildSection<SubtitlePostSessionActionItem>(
                context,
                title: '行动项',
                emptyLabel: '模型没有提取到行动项。',
                items: result.actionItems,
                buildItem: (item) => Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(item.action),
                    if (item.owner?.trim().isNotEmpty ?? false) ...[
                      const SizedBox(height: 3),
                      Text(
                        '负责人：${item.owner}',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                    const SizedBox(height: 6),
                    _ReviewSourceReferences(sources: item.sources),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSection<T>(
    BuildContext context, {
    required String title,
    required String emptyLabel,
    required List<T> items,
    required Widget Function(T item) buildItem,
  }) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 7),
          if (items.isEmpty)
            Text(
              emptyLabel,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: colors.onSurfaceVariant),
            )
          else
            for (final item in items)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: buildItem(item),
              ),
        ],
      ),
    );
  }
}

final class _ReviewSourceReferences extends StatelessWidget {
  const _ReviewSourceReferences({required this.sources});

  final List<SubtitlePostSessionSourceRef> sources;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 6,
    runSpacing: 4,
    children: [
      for (final source in sources)
        Tooltip(
          message: '音源 ID：${source.sourceId}\n采集轮次：${source.captureAttemptId}',
          child: Chip(
            avatar: const Icon(Icons.link_rounded, size: 15),
            visualDensity: VisualDensity.compact,
            label: Text(
              '${_sourceLabel(source.sourceKind)} · ${source.segmentId} · '
              '${_formatTimestampExact(source.startMs)}–'
              '${_formatTimestampExact(source.endMs)}',
            ),
          ),
        ),
    ],
  );
}

final class _HistoryStateCard extends StatelessWidget {
  const _HistoryStateCard({
    required this.icon,
    required this.title,
    required this.detail,
    this.action,
  });

  final IconData icon;
  final String title;
  final String detail;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        children: [
          Icon(icon, size: 34, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 12),
          Text(
            title,
            style: Theme.of(context).textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.w700),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(detail, textAlign: TextAlign.center),
          if (action != null) ...[const SizedBox(height: 12), action!],
        ],
      ),
    ),
  );
}

final class _HistoryLoadingSkeleton extends StatelessWidget {
  const _HistoryLoadingSkeleton();

  @override
  Widget build(BuildContext context) {
    final placeholder = Theme.of(context).colorScheme.surfaceContainerHighest;
    Widget bar(double width, double height) => Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: placeholder,
        borderRadius: BorderRadius.circular(height / 2),
      ),
    );

    return Semantics(
      label: '正在加载字幕历史',
      liveRegion: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const LinearProgressIndicator(minHeight: 2),
          const SizedBox(height: 16),
          for (var cardIndex = 0; cardIndex < 3; cardIndex++) ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        CircleAvatar(backgroundColor: placeholder, radius: 18),
                        const SizedBox(width: 12),
                        bar(cardIndex == 0 ? 190 : 150, 16),
                      ],
                    ),
                    const SizedBox(height: 16),
                    bar(double.infinity, 12),
                    const SizedBox(height: 9),
                    bar(cardIndex == 1 ? 310 : 230, 12),
                    if (cardIndex == 0) ...[
                      const SizedBox(height: 18),
                      bar(double.infinity, 54),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }
}

final class _StandaloneAudioRecordingCard extends StatelessWidget {
  const _StandaloneAudioRecordingCard({
    required this.recording,
    required this.videoRecordings,
    required this.busyVideoRecordingFileNames,
    required this.operationsLocked,
    required this.busyAudioPlaybackKeys,
    required this.audioPlaybackBusy,
    required this.busy,
    required this.onOpenFile,
    required this.onRecoverFile,
    required this.onOpenFolder,
    required this.onDelete,
    required this.onOpenVideo,
    required this.onDeleteVideo,
  });

  final SubtitleAudioIndexedRecording recording;
  final List<SubtitleVideoRecordingEntry> videoRecordings;
  final Set<String> busyVideoRecordingFileNames;
  final bool operationsLocked;
  final Set<String> busyAudioPlaybackKeys;
  final bool audioPlaybackBusy;
  final bool busy;
  final ValueChanged<SubtitleAudioIndexedFile> onOpenFile;
  final ValueChanged<SubtitleAudioRecoveryCandidate> onRecoverFile;
  final VoidCallback onOpenFolder;
  final VoidCallback onDelete;
  final ValueChanged<SubtitleVideoRecordingEntry> onOpenVideo;
  final ValueChanged<SubtitleVideoRecordingEntry> onDeleteVideo;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final completedWithoutAudio =
        recording.status == SubtitleAudioIndexedRecordingStatus.completed &&
        recording.emptyAudioSources > 0 &&
        recording.files.isEmpty;
    final statusColor = completedWithoutAudio
        ? colors.tertiary
        : switch (recording.status) {
            SubtitleAudioIndexedRecordingStatus.completed => colors.primary,
            SubtitleAudioIndexedRecordingStatus.incomplete => colors.error,
            SubtitleAudioIndexedRecordingStatus.unknown => colors.tertiary,
            SubtitleAudioIndexedRecordingStatus.failed => colors.error,
            SubtitleAudioIndexedRecordingStatus.interrupted => colors.tertiary,
          };
    final timestamp = recording.startedAtUtc.toLocal();
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        key: PageStorageKey<String>(
          'standalone-audio-${recording.recordingId}',
        ),
        leading: CircleAvatar(
          backgroundColor: colors.primaryContainer,
          foregroundColor: colors.onPrimaryContainer,
          child: const Icon(Icons.audio_file_outlined),
        ),
        title: Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const Text('仅录音'),
            _SmallStatusChip(
              label: completedWithoutAudio
                  ? '无音频数据'
                  : switch (recording.status) {
                      SubtitleAudioIndexedRecordingStatus.completed => '已完成',
                      SubtitleAudioIndexedRecordingStatus.incomplete => '有缺段',
                      SubtitleAudioIndexedRecordingStatus.unknown => '完整性未知',
                      SubtitleAudioIndexedRecordingStatus.failed => '录音失败',
                      SubtitleAudioIndexedRecordingStatus.interrupted => '已中断',
                    },
              color: statusColor,
            ),
          ],
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 5),
          child: Text(
            '${_formatDate(timestamp)}  ·  ${recording.files.length} 个可播放 WAV'
            '${recording.emptyAudioSources > 0 ? '  ·  ${recording.emptyAudioSources} 个音源无音频数据' : ''}'
            '${recording.recoveryCandidates.isNotEmpty ? '  ·  ${recording.recoveryCandidates.length} 个未完成音源' : ''}'
            '${recording.droppedFrames > 0 ? '  ·  丢帧 ${recording.droppedFrames}' : ''}'
            '${recording.discontinuities > 0 ? '  ·  断续 ${recording.discontinuities} 次' : ''}'
            '${recording.status == SubtitleAudioIndexedRecordingStatus.unknown ? '  ·  旧记录未记录完整性计数' : ''}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (busy)
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              IconButton(
                tooltip: recording.recoveryCandidates.isNotEmpty
                    ? '请先恢复未完成音源，避免丢失录音数据'
                    : audioPlaybackBusy
                    ? '请先关闭录音播放器，再删除'
                    : '删除这条录音',
                onPressed:
                    recording.recoveryCandidates.isNotEmpty || audioPlaybackBusy
                    ? null
                    : onDelete,
                icon: const Icon(Icons.delete_outline_rounded),
              ),
            const Icon(Icons.expand_more_rounded),
          ],
        ),
        childrenPadding: const EdgeInsets.fromLTRB(18, 0, 18, 16),
        children: [
          const Divider(height: 1),
          if (videoRecordings.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Row(
                children: [
                  Icon(
                    Icons.video_file_outlined,
                    color: colors.primary,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '本次会话录屏',
                    style: Theme.of(context).textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            for (final video in videoRecordings)
              _SessionVideoRecordingTile(
                recording: video,
                busy:
                    operationsLocked ||
                    busyVideoRecordingFileNames.contains(video.fileName),
                onOpen: () => onOpenVideo(video),
                onDelete: () => onDeleteVideo(video),
              ),
          ],
          if (recording.files.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  recording.emptyAudioSources > 0
                      ? '没有采集到音频数据，因此没有可播放 WAV。'
                      : '没有已完成的 WAV；如有保留的 PCM 数据，可创建恢复副本。',
                ),
              ),
            ),
          for (final recordingFile in recording.files)
            Builder(
              builder: (_) {
                final isOpening = busyAudioPlaybackKeys.contains(
                  '${recording.sessionId}:${recording.recordingId}:${recordingFile.file.path}',
                );
                return ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: isOpening
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.play_circle_outline_rounded),
                  title: Text(
                    isOpening
                        ? '正在打开${_sourceLabel(recordingFile.sourceKind)}录音…'
                        : '播放${_sourceLabel(recordingFile.sourceKind)}',
                  ),
                  subtitle: Text(
                    '${recordingFile.sampleRateHz} Hz · ${recordingFile.channelCount} 声道 · ${_formatByteCount(recordingFile.dataBytes + recordingFile.headerBytes)}'
                    '${recordingFile.droppedFrames > 0 ? ' · 丢帧 ${recordingFile.droppedFrames}' : ''}'
                    '${recordingFile.discontinuities > 0 ? ' · 断续 ${recordingFile.discontinuities} 次' : ''}',
                  ),
                  onTap: busy || isOpening
                      ? null
                      : () => onOpenFile(recordingFile),
                );
              },
            ),
          for (final candidate in recording.recoveryCandidates)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.restore_rounded),
              title: Text('恢复${_sourceLabel(candidate.sourceKind)}录音副本'),
              subtitle: Text(
                '${_formatByteCount(candidate.dataBytes)} PCM 数据'
                '${candidate.formatKnown ? ' · ${candidate.sampleRateHz} Hz · ${candidate.channelCount} 声道' : ' · 缺少音频格式信息'}',
              ),
              trailing: TextButton(
                onPressed: busy || candidate.dataBytes <= 0
                    ? null
                    : () => onRecoverFile(candidate),
                child: const Text('恢复'),
              ),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: busy ? null : onOpenFolder,
              icon: const Icon(Icons.folder_open_outlined),
              label: const Text('打开录音目录'),
            ),
          ),
        ],
      ),
    );
  }
}

final class _AudioRecoveryFormat {
  const _AudioRecoveryFormat({
    required this.sampleRateHz,
    required this.channelCount,
  });

  final int sampleRateHz;
  final int channelCount;
}

final class _AudioRecoveryFormatDialog extends StatefulWidget {
  const _AudioRecoveryFormatDialog({required this.candidate});

  final SubtitleAudioRecoveryCandidate candidate;

  @override
  State<_AudioRecoveryFormatDialog> createState() =>
      _AudioRecoveryFormatDialogState();
}

final class _AudioRecoveryFormatDialogState
    extends State<_AudioRecoveryFormatDialog> {
  static const _commonSampleRates = <int>[
    8000,
    11025,
    16000,
    22050,
    24000,
    32000,
    44100,
    48000,
    88200,
    96000,
  ];

  late int? _sampleRateHz;
  late int? _channelCount;

  @override
  void initState() {
    super.initState();
    _sampleRateHz = widget.candidate.sampleRateHz;
    _channelCount = widget.candidate.channelCount;
  }

  @override
  Widget build(BuildContext context) {
    final candidate = widget.candidate;
    final sampleRates = <int>{
      ..._commonSampleRates,
      if (candidate.sampleRateHz != null) candidate.sampleRateHz!,
    }.toList()..sort();
    final channels = <int>{
      1,
      2,
      3,
      4,
      5,
      6,
      7,
      8,
      if (candidate.channelCount != null) candidate.channelCount!,
    }.toList()..sort();
    return AlertDialog(
      title: Text(
        candidate.legacyMultichannelUpgrade ? '修复旧版多声道录音' : '恢复未完成录音',
      ),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              candidate.legacyMultichannelUpgrade
                  ? '这条旧录音使用了播放器可能无法识别的多声道 WAV 头。译学会创建标准兼容副本并保留原文件。'
                  : candidate.formatKnown
                  ? '原记录保存了音频格式。将按该格式生成新的 WAV 副本，原始文件保持不变。'
                  : '这条旧录音缺少采样率或声道信息。请按录音来源选择；恢复后可试听，原始文件保持不变。',
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<int>(
              initialValue: _sampleRateHz,
              decoration: const InputDecoration(labelText: '采样率'),
              items: sampleRates
                  .map(
                    (rate) => DropdownMenuItem<int>(
                      value: rate,
                      child: Text('$rate Hz'),
                    ),
                  )
                  .toList(growable: false),
              onChanged: candidate.sampleRateHz == null
                  ? (value) => setState(() => _sampleRateHz = value)
                  : null,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              initialValue: _channelCount,
              decoration: const InputDecoration(labelText: '声道数'),
              items: channels
                  .map(
                    (count) => DropdownMenuItem<int>(
                      value: count,
                      child: Text(count == 1 ? '单声道' : '$count 声道'),
                    ),
                  )
                  .toList(growable: false),
              onChanged: candidate.channelCount == null
                  ? (value) => setState(() => _channelCount = value)
                  : null,
            ),
            if (_channelCount != null &&
                _channelCount! > 2 &&
                candidate.channelMask == null) ...[
              const SizedBox(height: 10),
              Text(
                '原录音没有保留扬声器布局，恢复副本会标记为未映射多声道。若播放不正常，可再用译学内置播放器试听；原文件不会改动。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          onPressed: _sampleRateHz == null || _channelCount == null
              ? null
              : () => Navigator.of(context).pop(
                  _AudioRecoveryFormat(
                    sampleRateHz: _sampleRateHz!,
                    channelCount: _channelCount!,
                  ),
                ),
          icon: const Icon(Icons.restore_rounded),
          label: Text(
            candidate.legacyMultichannelUpgrade ? '创建兼容副本' : '创建恢复副本',
          ),
        ),
      ],
    );
  }
}

final class _VideoRecordingCard extends StatelessWidget {
  const _VideoRecordingCard({
    required this.recording,
    required this.busy,
    required this.onOpenVideo,
    required this.onOpenFolder,
    required this.onDelete,
  });

  final SubtitleVideoRecordingEntry recording;
  final bool busy;
  final VoidCallback onOpenVideo;
  final VoidCallback onOpenFolder;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final hasNoVideoData = recording.sizeBytes == 0;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: CircleAvatar(
                backgroundColor: colors.primaryContainer,
                foregroundColor: colors.onPrimaryContainer,
                child: const Icon(Icons.video_file_outlined),
              ),
              title: Text(
                recording.fileName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                recording.isIncomplete
                    ? hasNoVideoData
                          ? '录屏文件为空（0 B），没有可播放的视频数据'
                          : recording.canAttemptPlayback
                          ? '未完成录屏 · 可尝试播放；可保留原文件或删除'
                          : '未完成录屏 · 无法安全播放；可保留原文件或删除'
                    : '修改于 ${_formatDate(recording.modifiedAt.toLocal())}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (recording.isIncomplete)
                  Chip(
                    visualDensity: VisualDensity.compact,
                    avatar: Icon(Icons.warning_amber_rounded, size: 16),
                    label: Text(
                      hasNoVideoData
                          ? '无视频数据'
                          : recording.canAttemptPlayback
                          ? '未完成 · 可尝试播放'
                          : '未完成',
                    ),
                  )
                else
                  Chip(
                    visualDensity: VisualDensity.compact,
                    avatar: const Icon(Icons.timelapse_rounded, size: 16),
                    label: Text(_formatVideoDuration(recording.duration)),
                  ),
                Chip(
                  visualDensity: VisualDensity.compact,
                  avatar: const Icon(Icons.storage_outlined, size: 16),
                  label: Text(_formatByteCount(recording.sizeBytes)),
                ),
                FilledButton.tonalIcon(
                  onPressed:
                      busy ||
                          (recording.isIncomplete &&
                              !recording.canAttemptPlayback)
                      ? null
                      : onOpenVideo,
                  icon: busy
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.play_arrow_rounded),
                  label: Text(
                    recording.isIncomplete
                        ? hasNoVideoData
                              ? '没有画面可播放'
                              : recording.canAttemptPlayback
                              ? '尝试播放录屏'
                              : '视频未完成'
                        : '播放 / 打开视频',
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: busy ? null : onOpenFolder,
                  icon: const Icon(Icons.folder_open_outlined),
                  label: const Text('打开视频目录'),
                ),
                OutlinedButton.icon(
                  key: recording.isIncomplete
                      ? ValueKey<String>(
                          'subtitle-history-process-incomplete-video-${recording.fileName}',
                        )
                      : null,
                  onPressed: busy ? null : onDelete,
                  icon: Icon(
                    recording.isIncomplete
                        ? Icons.delete_sweep_outlined
                        : Icons.delete_outline_rounded,
                  ),
                  label: Text(recording.isIncomplete ? '处理未完成录屏' : '删除视频'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

final class _SmallStatusChip extends StatelessWidget {
  const _SmallStatusChip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(99),
    ),
    child: Text(
      label,
      style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
    ),
  );
}

IconData _kindIcon(SubtitleSessionKind kind) => switch (kind) {
  SubtitleSessionKind.video => Icons.movie_outlined,
  SubtitleSessionKind.meeting => Icons.groups_2_outlined,
  SubtitleSessionKind.livestream => Icons.live_tv_outlined,
};

String _kindLabel(SubtitleSessionKind kind) => switch (kind) {
  SubtitleSessionKind.video => '视频',
  SubtitleSessionKind.meeting => '会议',
  SubtitleSessionKind.livestream => '直播',
};

String _sourceLabel(SubtitleAudioSourceKind kind) => switch (kind) {
  SubtitleAudioSourceKind.systemOutput => '系统播放声音',
  SubtitleAudioSourceKind.applicationOutput => '单个应用声音',
  SubtitleAudioSourceKind.microphone => '麦克风',
};

bool _sameProviderRoute(
  SubtitlePostSessionProviderInfo left,
  SubtitlePostSessionProviderInfo right,
) =>
    left.kind == right.kind &&
    left.providerName.trim() == right.providerName.trim() &&
    left.remoteDestinationLabel?.trim() == right.remoteDestinationLabel?.trim();

String _sessionStatusLabel(SubtitleSessionHistoryStatus status) =>
    switch (status) {
      SubtitleSessionHistoryStatus.preparing => '准备中',
      SubtitleSessionHistoryStatus.capturing => '采集中',
      SubtitleSessionHistoryStatus.paused => '已暂停',
      SubtitleSessionHistoryStatus.completed => '已完成',
      SubtitleSessionHistoryStatus.interrupted => '已中断',
      SubtitleSessionHistoryStatus.failed => '失败',
    };

bool _isActiveSession(SubtitleSessionHistoryStatus status) => switch (status) {
  SubtitleSessionHistoryStatus.preparing ||
  SubtitleSessionHistoryStatus.capturing ||
  SubtitleSessionHistoryStatus.paused => true,
  SubtitleSessionHistoryStatus.completed ||
  SubtitleSessionHistoryStatus.interrupted ||
  SubtitleSessionHistoryStatus.failed => false,
};

String _translationStatusLabel(SubtitleTranslationStatus status) =>
    switch (status) {
      SubtitleTranslationStatus.awaitingFinal => '等待确认',
      SubtitleTranslationStatus.awaitingQueue => '待翻译',
      SubtitleTranslationStatus.queued => '排队中',
      SubtitleTranslationStatus.translating => '翻译中',
      SubtitleTranslationStatus.translated => '已翻译',
      SubtitleTranslationStatus.failed => '翻译失败',
      SubtitleTranslationStatus.cancelled => '翻译已取消',
      SubtitleTranslationStatus.skippedEmpty => '空字幕未翻译',
      SubtitleTranslationStatus.skippedDisabled => '翻译未开启，已保存原文',
      SubtitleTranslationStatus.skippedUnsupportedLanguage => '语种未识别，已保存原文',
      SubtitleTranslationStatus.skippedSameLanguage => '原文就是目标语种，已保存原文',
    };

String _transcriptLanguageLabel(String languageCode) =>
    AsrLanguageRegistry.displayLabel(languageCode) ??
    '未知语种（${languageCode.trim()}）';

Color _statusColor(BuildContext context, SubtitleSessionHistoryStatus status) {
  final colors = Theme.of(context).colorScheme;
  return switch (status) {
    SubtitleSessionHistoryStatus.completed => colors.primary,
    SubtitleSessionHistoryStatus.failed => colors.error,
    SubtitleSessionHistoryStatus.interrupted => colors.tertiary,
    SubtitleSessionHistoryStatus.preparing ||
    SubtitleSessionHistoryStatus.capturing ||
    SubtitleSessionHistoryStatus.paused => colors.onSurfaceVariant,
  };
}

String _formatDate(DateTime value) =>
    '${value.year}-${_twoDigits(value.month)}-${_twoDigits(value.day)} '
    '${_twoDigits(value.hour)}:${_twoDigits(value.minute)}';

String _formatByteCount(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

String _formatVideoDuration(Duration duration) {
  final seconds = duration.inSeconds;
  final hours = seconds ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  final remainder = seconds % 60;
  return hours > 0
      ? '$hours:${_twoDigits(minutes)}:${_twoDigits(remainder)}'
      : '${_twoDigits(minutes)}:${_twoDigits(remainder)}';
}

String _sessionTitle(SubtitleSessionRecord session) =>
    '${_kindLabel(session.kind)} · ${_formatDate(session.startedAtUtc.toLocal())}';

String _sessionSourceSummary(SubtitleSessionRecord session) {
  if (session.segments.isEmpty) return _sourceLabel(session.sourceKind);
  final sourceIds = <String>{};
  final sourceKinds = <SubtitleAudioSourceKind>{};
  for (final segment in session.segments) {
    sourceIds.add(segment.transcript.sourceId);
    sourceKinds.add(segment.transcript.sourceKind);
  }
  final labels = sourceKinds.map(_sourceLabel).toList(growable: false);
  if (sourceIds.length == 1 && labels.length == 1) return labels.single;
  return '多音源 · ${labels.join('、')} · ${sourceIds.length} 路';
}

String _sessionFileDate(SubtitleSessionRecord session) {
  final date = session.startedAtUtc.toLocal();
  return '${_kindLabel(session.kind)}-${date.year}${_twoDigits(date.month)}'
      '${_twoDigits(date.day)}-${_twoDigits(date.hour)}${_twoDigits(date.minute)}';
}

String _formatTimestamp(int milliseconds) {
  final hours = milliseconds ~/ 3600000;
  final minutes = milliseconds ~/ 60000 % 60;
  final seconds = milliseconds ~/ 1000 % 60;
  return '${_twoDigits(hours)}:${_twoDigits(minutes)}:${_twoDigits(seconds)}';
}

String _formatTimestampExact(int milliseconds) {
  final hours = milliseconds ~/ 3600000;
  final minutes = milliseconds ~/ 60000 % 60;
  final seconds = milliseconds ~/ 1000 % 60;
  final millis = milliseconds % 1000;
  return '${_twoDigits(hours)}:${_twoDigits(minutes)}:'
      '${_twoDigits(seconds)}.${millis.toString().padLeft(3, '0')}';
}

String _shortenId(String value) => value.length <= 28
    ? value
    : '${value.substring(0, 12)}…${value.substring(value.length - 10)}';

String _twoDigits(int value) => value.toString().padLeft(2, '0');
