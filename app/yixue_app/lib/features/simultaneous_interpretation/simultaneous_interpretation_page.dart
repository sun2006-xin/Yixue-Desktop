import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';
import 'package:yixue_app/core/app_data_directory.dart';
import 'package:yixue_app/core/app_exit_cleanup_registry.dart';
import 'package:yixue_app/core/quick_translation_service.dart';

import 'asr_language_registry.dart';
import 'asr_route_summary.dart';
import 'audio_capture_contract.dart';
import 'audio_capture_stop_coordinator.dart';
import 'desktop_audio_capture.dart';
import 'live_subtitle_session.dart';
import 'multilingual_asr_model_store.dart';
import 'streaming_asr.dart';
import 'streaming_asr_model_store.dart';
import 'subtitle_session_contract.dart';
import 'subtitle_display_preferences.dart';
import 'subtitle_text_presentation.dart';
import 'subtitle_session_persistence.dart';
import 'subtitle_session_store.dart';
import 'subtitle_translation_queue.dart';
import 'subtitle_audio_recording.dart';
import 'screen_recording_startup_gate.dart';
import 'desktop_screen_recording.dart';
import 'desktop_screen_capture.dart';
import 'subtitle_window_host.dart';
import 'subtitle_window_view.dart';
import 'subtitle_history_navigation.dart';

/// Provider metadata and the matching executor prepared by app composition.
///
/// The workbench does not infer whether an executor is local or remote from
/// its concrete type. The caller must create this value from the same frozen
/// provider route snapshot used by [executor], including all requested source
/// directions in Auto mode. [remoteDestinationLabel] is display-safe text; it
/// must not contain credentials or secret URL components.
final class LiveSubtitleTranslationSetup {
  const LiveSubtitleTranslationSetup({
    required this.executor,
    required this.routeKind,
    required this.providerLabel,
    this.remoteDestinationLabel,
    this.detail,
  });

  final SubtitleTranslationExecutor executor;
  final SubtitleTranslationRouteKind routeKind;
  final String providerLabel;
  final String? remoteDestinationLabel;
  final String? detail;
}

typedef LiveSubtitleTranslationSetupLoader =
    Future<LiveSubtitleTranslationSetup> Function({
      required List<String> sourceLanguageCodes,
      required String targetLanguageCode,
    });

/// Shares one asynchronous disposal operation across overlapping lifecycle
/// paths, such as successful app-exit preparation and widget teardown.
@visibleForTesting
final class MemoizedAsyncDisposal {
  Future<void>? _disposal;

  Future<void> run(Future<void> Function() dispose) {
    final currentDisposal = _disposal;
    if (currentDisposal != null) return currentDisposal;

    late final Future<void> disposal;
    disposal = Future<void>.sync(dispose).then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        if (identical(_disposal, disposal)) _disposal = null;
        Error.throwWithStackTrace(error, stackTrace);
      },
    );
    _disposal = disposal;
    return disposal;
  }
}

/// Visible language label for a transcript revision returned by ASR.
///
/// This takes the actual revision language code. The selector value `auto` is
/// intentionally not a language and will be shown as unknown if it leaks into
/// a transcript revision.
final class SubtitleTranscriptLanguageBadge extends StatelessWidget {
  const SubtitleTranscriptLanguageBadge({
    required this.languageCode,
    super.key,
  });

  final String languageCode;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: '识别语种：${_transcriptLanguageLabel(languageCode)}',
    child: Text(
      _transcriptLanguageLabel(languageCode),
      key: ValueKey('subtitle-transcript-language-$languageCode'),
      style: Theme.of(context).textTheme.labelSmall
          ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
    ),
  );
}

/// Native window operations used by the compact subtitle window.
///
/// This narrow boundary keeps the transition testable without opening a real
/// desktop window or invoking platform channels.
abstract interface class CompactSubtitleWindowActions {
  Future<bool> isMaximized();

  Future<Rect> getBounds();

  Future<bool> isResizable();

  Future<bool> isAlwaysOnTop();

  Future<void> unmaximize();

  Future<void> maximize();

  Future<void> setMinimumSize(Size size);

  Future<void> setResizable(bool value);

  Future<void> setAlwaysOnTop(bool value);

  Future<void> setBounds(Rect? bounds, {Offset? position, Size? size});

  Future<void> setSize(Size size);

  Future<void> startDragging();
}

/// Window settings saved before compact subtitle mode changes the native
/// window. Kept public so the transition boundary can be regression-tested.
final class CompactSubtitleWindowRestoreState {
  const CompactSubtitleWindowRestoreState({
    required this.bounds,
    required this.minimumSize,
    required this.isResizable,
    required this.isAlwaysOnTop,
    required this.wasMaximized,
  });

  final Rect bounds;
  final Size minimumSize;
  final bool isResizable;
  final bool isAlwaysOnTop;
  final bool wasMaximized;
}

/// Reports the original native failure and whether the rollback completed.
final class CompactSubtitleWindowTransitionException implements Exception {
  const CompactSubtitleWindowTransitionException(
    this.cause, {
    required this.restored,
  });

  final Object cause;
  final bool restored;

  @override
  String toString() =>
      'Compact subtitle window transition failed: $cause '
      '(restored: $restored)';
}

/// Enters compact mode transactionally. If a platform operation fails, every
/// restoration operation is attempted before the original failure is exposed.
/// The generation/cancellation check runs after Flutter has laid out the
/// compact tree and before the delayed native resize is issued.
Future<CompactSubtitleWindowRestoreState?> enterCompactSubtitleWindow({
  required CompactSubtitleWindowActions actions,
  required Size normalMinimumSize,
  required Size compactMinimumSize,
  required Size compactSize,
  required bool Function() canContinue,
  required Future<void> Function() waitForLayout,
  required ValueChanged<CompactSubtitleWindowRestoreState?>
  onRestoreStateChanged,
  required ValueChanged<bool> onCompactModeChanged,
}) async {
  CompactSubtitleWindowRestoreState? restoreState;
  try {
    final wasMaximized = await actions.isMaximized();
    final capturedRestoreState = CompactSubtitleWindowRestoreState(
      bounds: await actions.getBounds(),
      minimumSize: normalMinimumSize,
      isResizable: await actions.isResizable(),
      isAlwaysOnTop: await actions.isAlwaysOnTop(),
      wasMaximized: wasMaximized,
    );
    restoreState = capturedRestoreState;
    onRestoreStateChanged(capturedRestoreState);

    if (wasMaximized) await actions.unmaximize();
    await actions.setMinimumSize(compactMinimumSize);
    await actions.setResizable(true);
    await actions.setAlwaysOnTop(true);
    onCompactModeChanged(true);
    await waitForLayout();

    if (!canContinue()) {
      await restoreCompactSubtitleWindow(
        actions: actions,
        state: capturedRestoreState,
      );
      onRestoreStateChanged(null);
      onCompactModeChanged(false);
      return null;
    }

    await actions.setBounds(
      null,
      position: capturedRestoreState.bounds.topLeft,
      size: compactSize,
    );
    return capturedRestoreState;
  } on Object catch (error, stackTrace) {
    var restored = restoreState == null;
    if (restoreState != null) {
      try {
        await restoreCompactSubtitleWindow(
          actions: actions,
          state: restoreState,
        );
        restored = true;
      } on Object {
        restored = false;
      }
    }
    onRestoreStateChanged(restored ? null : restoreState);
    onCompactModeChanged(!restored);
    Error.throwWithStackTrace(
      CompactSubtitleWindowTransitionException(error, restored: restored),
      stackTrace,
    );
  }
}

/// Attempts every restore step even if an earlier native operation failed.
Future<void> restoreCompactSubtitleWindow({
  required CompactSubtitleWindowActions actions,
  required CompactSubtitleWindowRestoreState state,
}) async {
  Object? firstError;
  StackTrace? firstStackTrace;
  Future<void> attempt(Future<void> Function() action) async {
    try {
      await action();
    } on Object catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }
  }

  await attempt(() => actions.setMinimumSize(state.minimumSize));
  await attempt(() => actions.setResizable(state.isResizable));
  if (state.wasMaximized) {
    await attempt(actions.maximize);
  } else {
    await attempt(actions.unmaximize);
    await attempt(() => actions.setBounds(state.bounds));
  }
  await attempt(() => actions.setAlwaysOnTop(state.isAlwaysOnTop));
  if (firstError != null) {
    Error.throwWithStackTrace(firstError!, firstStackTrace!);
  }
}

/// Applies one queued native resize only while its owning compact-mode
/// generation is current. A cancelled exit invalidates the generation before
/// any later timer/pump callback can submit another resize.
Future<bool> applyCompactSubtitleResizeIfCurrent({
  required int generation,
  required int currentGeneration,
  required bool canResize,
  required Size size,
  required Future<void> Function(Size size) apply,
}) async {
  if (generation != currentGeneration || !canResize) return false;
  await apply(size);
  return true;
}

String _transcriptLanguageLabel(String languageCode) =>
    AsrLanguageRegistry.displayLabel(languageCode) ??
    '未知语种（${languageCode.trim()}）';

/// Persistent shell notice for captures that continue while another workspace
/// is visible.
final class SimultaneousInterpretationActivityBanner extends StatelessWidget {
  const SimultaneousInterpretationActivityBanner({
    required this.status,
    required this.onReturn,
    super.key,
  });

  final ValueListenable<String?> status;
  final VoidCallback onReturn;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<String?>(
    valueListenable: status,
    builder: (context, value, _) {
      if (value == null || value.isEmpty) return const SizedBox.shrink();
      final colors = Theme.of(context).colorScheme;
      return ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Material(
          key: const ValueKey('active-subtitle-activity-banner'),
          color: colors.surface,
          elevation: 8,
          shadowColor: colors.shadow.withValues(alpha: 0.16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: colors.outlineVariant),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.sensors_rounded, color: colors.error, size: 19),
                const SizedBox(width: 9),
                Flexible(
                  child: Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                ),
                const SizedBox(width: 8),
                TextButton.icon(
                  key: const ValueKey('return-to-live-subtitles'),
                  onPressed: onReturn,
                  icon: const Icon(Icons.subtitles_rounded, size: 17),
                  label: const Text('返回同传'),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

/// Desktop live subtitle workbench. All platform, model, persistence, and
/// translation dependencies are supplied by the application composition.
final class LiveSubtitleWorkbenchPage extends StatefulWidget {
  LiveSubtitleWorkbenchPage({
    required this.capture,
    required this.asrRuntime,
    required this.modelStore,
    required this.multilingualModelStore,
    required this.sessionStore,
    required this.displayPreferencesStore,
    required this.translationSetupLoader,
    required this.onOpenHistory,
    required this.appDataDirectory,
    this.activityStatus,
    this.onCompactModeChanged,
    this.screenCapture,
    this.subtitleWindowController,
    this.compactSubtitleWindowActions,
    this.workbenchMinimumWindowSize = const Size(960, 620),
    DateTime Function()? clock,
    String Function()? idFactory,
    super.key,
  }) : clock = clock ?? DateTime.now,
       idFactory = idFactory ?? _newId;

  final DesktopAudioCaptureAdapter capture;
  final StreamingAsrRuntime asrRuntime;
  final StreamingAsrModelStore modelStore;
  final MultilingualAsrModelStore multilingualModelStore;
  final SubtitleSessionStore sessionStore;
  final SubtitleDisplayPreferencesStore displayPreferencesStore;
  final LiveSubtitleTranslationSetupLoader translationSetupLoader;
  final Future<void> Function() onOpenHistory;
  final String appDataDirectory;
  final ValueNotifier<String?>? activityStatus;
  final ValueChanged<bool>? onCompactModeChanged;
  final DesktopScreenCaptureAdapter? screenCapture;
  final SubtitleWindowController? subtitleWindowController;
  final CompactSubtitleWindowActions? compactSubtitleWindowActions;

  /// `window_manager 0.5.2` has no getter for the current minimum size. This
  /// value mirrors the application's normal window configuration and is
  /// restored when the user exits the compact always-on-top mode.
  final Size workbenchMinimumWindowSize;
  final DateTime Function() clock;
  final String Function() idFactory;

  static String _newId() {
    final bytes = List<int>.generate(16, (_) => Random.secure().nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((value) => value.toRadixString(16).padLeft(2, '0'));
    final value = hex.join();
    return '${value.substring(0, 8)}-${value.substring(8, 12)}-'
        '${value.substring(12, 16)}-${value.substring(16, 20)}-'
        '${value.substring(20)}';
  }

  @override
  State<LiveSubtitleWorkbenchPage> createState() =>
      _LiveSubtitleWorkbenchPageState();
}

class _LiveSubtitleWorkbenchPageState extends State<LiveSubtitleWorkbenchPage> {
  static const _compactMinimumSize = Size(520, 220);
  static const _compactWindowSize = Size(700, 320);
  static const _sessionUiUpdateInterval = Duration(milliseconds: 50);
  static const _subtitleWindowUpdateInterval = Duration(milliseconds: 100);

  final ScrollController _transcriptScrollController = ScrollController();
  final ExpansibleController _unifiedSettingsController =
      ExpansibleController();
  final ExpansibleController _languageSettingsController =
      ExpansibleController();
  final ExpansibleController _recordingSettingsController =
      ExpansibleController();
  final ExpansibleController _appearanceSettingsController =
      ExpansibleController();
  final ExpansibleController _privacySettingsController =
      ExpansibleController();
  final GlobalKey _audioSourceSettingsKey = GlobalKey(
    debugLabel: 'subtitle-audio-source-settings',
  );
  final GlobalKey _microphoneSourceSettingsKey = GlobalKey(
    debugLabel: 'subtitle-microphone-source-settings',
  );
  final GlobalKey _microphoneDeviceSettingsKey = GlobalKey(
    debugLabel: 'subtitle-microphone-device-settings',
  );
  final GlobalKey _recognitionModelSettingsKey = GlobalKey(
    debugLabel: 'subtitle-recognition-model-settings',
  );
  final Set<Completer<void>> _trackedOperations = {};
  late final VoidCallback _unregisterExitCleanup;
  Future<void>? _pageResourcesDisposal;
  late final SubtitleAudioSessionRecorder _audioRecorder;
  final MemoizedAsyncDisposal _audioRecorderDisposal = MemoizedAsyncDisposal();
  StreamSubscription<SubtitleAudioRecordingState>? _audioRecordingSubscription;
  StreamSubscription<AudioCaptureSourceState>? _audioOnlySourceSubscription;
  SubtitleAudioRecordingState _audioRecordingState =
      SubtitleAudioRecordingState.idle();
  final Map<String, AudioCaptureSourceState> _audioOnlySourceStates = {};
  List<DesktopAudioCaptureSource> _audioOnlySources = const [];
  String? _audioOnlySessionId;
  String? _audioOnlyCaptureAttemptId;
  bool _audioOnlyRecordingActive = false;
  final DesktopScreenRecordingAdapter _screenRecorder =
      DesktopScreenRecordingAdapter();
  DesktopScreenRecordingState _screenRecordingState =
      const DesktopScreenRecordingState(status: 'idle');
  Timer? _screenStatePollTimer;
  bool _screenStatePollInProgress = false;
  bool _screenRecordingOperationInProgress = false;
  Future<void>? _screenStopFuture;
  bool _screenRecordingWithAudio = true;
  bool _screenAudioWriterReady = false;
  bool _screenOwnsAudioSource = false;
  bool _screenRecordingStopRequested = false;
  bool _screenAudioWriteFailed = false;
  String? _screenAudioWriteFailureMessage;
  String? _screenRecordingSessionId;
  DesktopAudioCaptureSource? _screenRecordingAudioSource;
  StreamSubscription<AudioFrame>? _screenAudioFrameSubscription;
  ScreenRecordingAudioFrameSubscriptionLease?
  _screenAudioFrameSubscriptionLease;
  int _screenAudioCaptureGeneration = 0;
  final ScreenRecordingAudioPreRoll _screenAudioPreRoll =
      ScreenRecordingAudioPreRoll();
  Future<void> _screenAudioWriteTail = Future<void>.value();

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    widget.activityStatus?.value = _activityStatusLabel;
  }

  List<DesktopAudioCaptureSource> _sources = const [];
  List<DesktopAudioCaptureSource> _microphoneSources = const [];
  String? _selectedSourceId;
  String? _selectedMicrophoneSourceId;
  bool _systemAudioEnabled = true;
  bool _microphoneCaptureEnabled = false;
  bool _retainSessionAudio = false;
  String? _sourceLoadError;
  bool _loadingSources = false;

  SubtitleSessionKind _sessionKind = SubtitleSessionKind.video;
  // The shipped streaming recognizer covers English and Chinese. Chinese to
  // English is the workbench default so Chinese videos produce the expected
  // English subtitle without requiring a language change before every session.
  String _sourceLanguageCode = 'zh';
  String _targetLanguageCode = 'en';
  bool _translationEnabled = true;
  bool _changingLanguages = false;
  int _languageChangeGeneration = 0;

  bool? _modelInstalled;
  bool _checkingModel = true;
  bool _downloadingModel = false;
  bool _cancelModelDownload = false;
  StreamingAsrModelDownloadProgress? _modelDownloadProgress;
  String? _modelErrorCode;
  int _modelCheckGeneration = 0;

  LiveSubtitleTranslationSetup? _translationSetup;
  bool _loadingTranslationSetup = false;
  String? _translationSetupError;
  int _routeLoadGeneration = 0;

  LiveSubtitleSession? _session;
  LiveSubtitleSessionState? _sessionState;
  StreamSubscription<LiveSubtitleSessionState>? _sessionSubscription;
  String? _diagnosticSessionId;
  StreamSubscription<DesktopScreenCaptureEvent>? _screenCaptureSubscription;
  bool _operationInProgress = false;
  bool _cancelledExitWaitPending = false;
  bool _directionChangeInProgress = false;
  bool _windowTransitionInProgress = false;
  bool _exitPreparationSucceeded = false;
  String? _operationLabel;
  String? _operationErrorCode;

  DesktopScreenCaptureTarget? _screenTarget;
  bool? _screenCaptureSupported;
  bool _screenCaptureChecking = false;
  bool _screenCaptureBusy = false;
  bool _isPreparingForAppExit = false;
  bool _screenRecording = false;
  String? _screenCaptureError;
  String? _recordingPath;
  String? _lastRecordingPath;
  List<SubtitleSessionRecord> _recentSessions = const [];

  bool _compactWindowMode = false;
  int _compactWindowTransitionGeneration = 0;
  int _compactResizeGeneration = 0;
  bool _subtitleWindowVisible = false;
  bool _subtitleWindowBusy = false;
  bool _historyNavigationInProgress = false;
  bool _historyRouteVisible = false;
  String? _subtitleWindowFailure;
  bool _subtitleWindowUpdateFailureReported = false;
  Timer? _subtitleWindowUpdateTimer;
  LiveSubtitleSessionState? _pendingSubtitleWindowState;
  Timer? _sessionUiUpdateTimer;
  LiveSubtitleSession? _pendingUiSession;
  LiveSubtitleSessionState? _pendingUiSessionState;
  late final SubtitleWindowController _subtitleWindowHost =
      widget.subtitleWindowController ??
      SubtitleWindowHost(
        onVisibilityChanged: (visible) {
          if (mounted) setState(() => _subtitleWindowVisible = visible);
        },
        onFailure: _reportSubtitleWindowFailure,
        onControlAction: _handleSubtitleWindowControlAction,
      );
  SubtitleDisplayPreferences _displayPreferences =
      SubtitleDisplayPreferences.defaults;
  int _displayPreferenceGeneration = 0;
  CompactSubtitleWindowRestoreState? _windowRestoreState;
  Rect? _resizeStartBounds;
  Offset? _resizeStartPointer;
  Timer? _compactResizeTimer;
  Size? _queuedCompactWindowSize;
  Future<void>? _compactResizeFuture;

  CompactSubtitleWindowActions get _compactWindowActions =>
      widget.compactSubtitleWindowActions ??
      _WindowManagerCompactSubtitleWindowActions();

  bool get _isDesktop => Platform.isWindows || Platform.isMacOS;

  bool _usesMultilingualModel(String languageCode) =>
      AsrLanguageRegistry.usesMultilingualModel(languageCode);

  DesktopAudioCaptureSource? get _selectedSource {
    final selectedId = _selectedSourceId;
    if (selectedId == null) return null;
    for (final source in _sources) {
      if (source.sourceId == selectedId) return source;
    }
    return null;
  }

  DesktopAudioCaptureSource? get _selectedMicrophoneSource {
    final selectedId = _selectedMicrophoneSourceId;
    if (selectedId == null) return null;
    for (final source in _microphoneSources) {
      if (source.sourceId == selectedId) return source;
    }
    return null;
  }

  List<DesktopAudioCaptureSource> get _selectedCaptureSources {
    final sources = <DesktopAudioCaptureSource>[];
    final system = _selectedSource;
    final microphone = _selectedMicrophoneSource;
    if (_systemAudioEnabled && system != null) sources.add(system);
    if (_microphoneCaptureEnabled && microphone != null) {
      sources.add(microphone);
    }
    return List<DesktopAudioCaptureSource>.unmodifiable(sources);
  }

  bool get _canStartAudioOnly =>
      Platform.isWindows &&
      !_loadingSources &&
      _selectedCaptureSources.isNotEmpty &&
      !_sessionIsActive &&
      !_audioOnlyRecordingActive &&
      !_screenRecording &&
      !_screenRecordingActive &&
      !_screenRecordingOperationInProgress &&
      canStartAudioCaptureAfterScreenRecordingCleanup(
        _screenRecordingCleanupStatus,
        screenRecordingStopInProgress: _screenStopFuture != null,
        audioSubscriptionCleanupUnconfirmed:
            _screenAudioFrameSubscription != null,
      ) &&
      !_operationInProgress &&
      !_downloadingModel &&
      _audioRecorder.canStart;

  String get _screenRecordingDirectoryPath => joinAppDataPath(
    widget.appDataDirectory,
    'simultaneous-interpretation/video-recordings',
  );

  ScreenRecordingCleanupStatus get _screenRecordingCleanupStatus =>
      resolveScreenRecordingCleanupStatus(
        ownsAudioSource: _screenOwnsAudioSource,
        source: _screenRecordingAudioSource,
        sessionId: _screenRecordingSessionId,
      );

  bool get _hasUnconfirmedScreenRecordingCleanup =>
      !canStartAudioCaptureAfterScreenRecordingCleanup(
        _screenRecordingCleanupStatus,
        audioSubscriptionCleanupUnconfirmed:
            _screenAudioFrameSubscription != null,
      );

  SubtitleSessionStatus? get _sessionStatus =>
      _sessionState?.coordinator?.status;

  String get _audioRecordingDescription => switch (_audioRecordingState
      .status) {
    SubtitleAudioRecordingStatus.recording => '正在分音源保存 WAV；字幕与录音分开存储，不会自动上传。',
    SubtitleAudioRecordingStatus.stopping => '正在完成本机音频文件。',
    SubtitleAudioRecordingStatus.stopped => '本次音频已保存在本机 WAV 文件中；下一次会话需重新开启此开关。',
    SubtitleAudioRecordingStatus.failed => '音频未能完整保存；字幕会话仍单独保留。下一次会话需重新开启。',
    SubtitleAudioRecordingStatus.idle =>
      _retainSessionAudio
          ? '已为下一次会话开启；每个音源单独保存本机 WAV，字幕与录音分开且不自动上传。'
          : '默认关闭；开启后每个音源单独保存本机 WAV，字幕与录音分开且不自动上传。',
  };

  String get _audioOnlyRecordingDescription {
    if (!_audioOnlyRecordingActive) {
      return '不启动 ASR 或字幕，直接把所选音源保存为本机 WAV。';
    }
    final sourceStates = _audioOnlySources
        .map(
          (source) =>
              _audioOnlySourceStates[_audioOnlySourceIdentity(
                source.sourceKind,
                source.sourceId,
              )],
        )
        .toList(growable: false);
    if (sourceStates.any(
      (state) =>
          state?.status == AudioCaptureSourceStatus.permissionDenied ||
          state?.status == AudioCaptureSourceStatus.deviceUnavailable ||
          state?.status == AudioCaptureSourceStatus.deviceDisconnected ||
          state?.status == AudioCaptureSourceStatus.failed,
    )) {
      return '部分音源不可用；已收到的音频仍按本机 WAV 文件收尾。';
    }
    if (sourceStates.any(
      (state) => state?.status == AudioCaptureSourceStatus.active,
    )) {
      return '音源已送入录音；停止后可从录音历史中打开或删除文件。';
    }
    return '录制已启动，正在等待 Windows 音源首帧；首帧到来前没有有效音频写入。';
  }

  bool get _sessionIsActive => switch (_sessionStatus) {
    SubtitleSessionStatus.preparing ||
    SubtitleSessionStatus.capturing ||
    SubtitleSessionStatus.paused ||
    SubtitleSessionStatus.stopping => true,
    SubtitleSessionStatus.idle ||
    SubtitleSessionStatus.stopped ||
    SubtitleSessionStatus.failed ||
    null => false,
  };

  bool get _hasAsrFailure => _subtitleAsrHasFailure(
    _sessionState?.asr,
    _sessionState?.errorCodes ?? const <String>[],
  );

  String? get _activityStatusLabel {
    if (_isPreparingForAppExit) return '正在安全停止采集并保存记录';
    final status = _sessionStatus;
    if (status == SubtitleSessionStatus.capturing ||
        status == SubtitleSessionStatus.preparing ||
        status == SubtitleSessionStatus.stopping) {
      return _screenRecordingActive ? 'AI 同传与屏幕录制正在运行' : 'AI 同传正在采集音频';
    }
    if (status == SubtitleSessionStatus.paused) return 'AI 同传已暂停';
    if (_screenRecordingActive) return '屏幕录制正在运行';
    if (_audioOnlyRecordingActive) return '独立录音正在运行';
    if (_audioRecordingState.status == SubtitleAudioRecordingStatus.recording) {
      return '同传音频正在保存到本机';
    }
    if (_screenOwnsAudioSource) return '录屏音源停止未确认，请返回同传处理';
    if (_screenTarget != null) return '桌面画面预览正在运行';
    return null;
  }

  // A selected but idle preview may be released before opening history.
  // Active media must finish first so its native texture/recording survives.
  bool get _canOpenHistory =>
      !_isPreparingForAppExit &&
      !_historyNavigationInProgress &&
      !_operationInProgress &&
      !_screenCaptureBusy &&
      !_screenRecording &&
      !_screenRecordingActive &&
      !_screenOwnsAudioSource &&
      !_audioOnlyRecordingActive &&
      _audioRecordingState.status != SubtitleAudioRecordingStatus.recording &&
      _audioRecordingState.status != SubtitleAudioRecordingStatus.stopping &&
      !_sessionIsActive;

  List<SubtitleSegment> get _visibleSegments {
    final segments =
        _sessionState?.coordinator?.segments ?? const <SubtitleSegment>[];
    // A higher-revision empty final is a tombstone for a previously visible
    // interim caption. Keep it in coordinator state, but never render or retry
    // it as a blank subtitle.
    return segments
        .where((segment) => segment.transcript.text.trim().isNotEmpty)
        .toList(growable: false);
  }

  bool get _canEnterCompactWindowMode =>
      _isDesktop &&
      _session != null &&
      !_subtitleWindowVisible &&
      !_subtitleWindowBusy &&
      !_windowTransitionInProgress &&
      !_operationInProgress &&
      !_isPreparingForAppExit &&
      (_sessionIsActive || _visibleSegments.isNotEmpty);

  bool get _canOpenSubtitleWindow =>
      Platform.isWindows &&
      _session != null &&
      (_sessionIsActive || _visibleSegments.isNotEmpty);

  bool get _screenRecordingActive => _screenRecordingState.isRecording;

  bool get _canStart =>
      _isDesktop &&
      !_loadingSources &&
      _modelInstalled == true &&
      _selectedCaptureSources.isNotEmpty &&
      _audioRecorder.canStart &&
      !_screenCaptureBusy &&
      !_screenRecording &&
      !_screenRecordingActive &&
      !_screenRecordingOperationInProgress &&
      canStartAudioCaptureAfterScreenRecordingCleanup(
        _screenRecordingCleanupStatus,
        screenRecordingStopInProgress: _screenStopFuture != null,
        audioSubscriptionCleanupUnconfirmed:
            _screenAudioFrameSubscription != null,
      ) &&
      (!_translationEnabled ||
          (!_loadingTranslationSetup &&
              _translationSetupError == null &&
              _translationSetup != null &&
              _translationSetup!.routeKind !=
                  SubtitleTranslationRouteKind.unavailable)) &&
      !_downloadingModel &&
      !_changingLanguages &&
      !_operationInProgress &&
      !_audioOnlyRecordingActive &&
      !_sessionIsActive;

  @override
  void initState() {
    super.initState();
    _audioRecorder = SubtitleAudioSessionRecorder(
      appDataDirectory: Directory(widget.appDataDirectory),
    );
    _audioRecordingSubscription = _audioRecorder.states.listen(
      (state) {
        if (mounted) setState(() => _audioRecordingState = state);
      },
      onError: (_) {
        if (mounted) _showMessage('音频录制状态读取失败；字幕会话仍可继续。');
      },
    );
    _unregisterExitCleanup = AppExitCleanupRegistry.register(
      _prepareForAppExit,
      name: 'simultaneous.interpretation',
    );
    final screenCapture = widget.screenCapture;
    if (screenCapture != null) {
      _screenCaptureSubscription = screenCapture.events.listen(
        _onScreenCaptureEvent,
        onError: (_) {
          if (mounted) {
            setState(() => _screenCaptureError = '桌面画面状态连接中断。');
          }
        },
      );
      unawaited(_checkScreenCaptureSupport());
    }
    unawaited(_loadRecentSessions());
    unawaited(_refreshSources());
    unawaited(_checkModelInstallation());
    unawaited(_loadTranslationSetup());
    unawaited(_loadDisplayPreferences());
  }

  Future<void> _loadDisplayPreferences() async {
    final generation = _displayPreferenceGeneration;
    try {
      final preferences = await widget.displayPreferencesStore.read();
      if (!mounted || generation != _displayPreferenceGeneration) return;
      setState(() => _displayPreferences = preferences);
    } catch (_) {
      if (mounted) _showMessage('读取字幕显示设置失败，已使用默认样式。');
    }
  }

  void _updateDisplayPreferences(SubtitleDisplayPreferences preferences) {
    if (preferences.mode == _displayPreferences.mode &&
        preferences.fontScale == _displayPreferences.fontScale &&
        preferences.colorPreset == _displayPreferences.colorPreset &&
        preferences.highContrast == _displayPreferences.highContrast &&
        preferences.windowOpacity == _displayPreferences.windowOpacity) {
      return;
    }
    _displayPreferenceGeneration += 1;
    setState(() => _displayPreferences = preferences);
    unawaited(_saveDisplayPreferences(preferences));
  }

  Future<void> _saveDisplayPreferences(
    SubtitleDisplayPreferences preferences,
  ) async {
    try {
      await widget.displayPreferencesStore.write(preferences);
    } catch (_) {
      if (mounted) _showMessage('字幕样式已应用，但未能保存到本机。');
    }
  }

  @override
  void dispose() {
    _compactWindowTransitionGeneration++;
    _compactResizeGeneration++;
    _queuedCompactWindowSize = null;
    _cancelSubtitleWindowUpdate();
    _cancelPendingSessionUiUpdate();
    _cancelModelDownload = true;
    _compactResizeTimer?.cancel();
    _compactResizeTimer = null;
    _screenStatePollTimer?.cancel();
    _screenStatePollTimer = null;
    unawaited(_sessionSubscription?.cancel());
    unawaited(_screenCaptureSubscription?.cancel());
    unawaited(_audioRecordingSubscription?.cancel());
    unawaited(_audioOnlySourceSubscription?.cancel());
    final screenAudioFrameSubscriptionLease =
        _screenAudioFrameSubscriptionLease;
    if (screenAudioFrameSubscriptionLease != null) {
      unawaited(
        cancelScreenRecordingAudioFrameSubscriptionForDisposal(
          lease: screenAudioFrameSubscriptionLease,
        ),
      );
    }
    _transcriptScrollController.dispose();
    _unifiedSettingsController.dispose();
    _languageSettingsController.dispose();
    _recordingSettingsController.dispose();
    _appearanceSettingsController.dispose();
    _privacySettingsController.dispose();

    final session = _session;
    final disposal = _disposePageResources(session);
    _pageResourcesDisposal = disposal;
    unawaited(
      disposal.then<void>(
        (_) {
          if (!identical(_pageResourcesDisposal, disposal)) return;
          _pageResourcesDisposal = null;
          _unregisterExitCleanup();
        },
        onError: (Object _, StackTrace __) {
          if (identical(_pageResourcesDisposal, disposal)) {
            // Keep the close hook registered so the app can retry cleanup if
            // page teardown itself fails while navigation is in flight.
            _pageResourcesDisposal = null;
          }
        },
      ),
    );
    super.dispose();
  }

  Future<void> _disposePageResources(LiveSubtitleSession? session) async {
    // A page can be removed while a native window or capture operation is in
    // flight. Let its tracked owner finish before starting teardown against
    // the same platform channels.
    await _waitForTrackedOperations();
    if (!_exitPreparationSucceeded) {
      await _disposeCaptureAndRecorder(session);
      if (_windowRestoreState != null) {
        try {
          await _restoreWindowState(updateUi: false);
        } on Object {
          // The application is leaving this page; native window shutdown is
          // the final fallback if restoring its normal bounds fails.
        }
      }
    }
    if (session != null) {
      try {
        await session.dispose();
      } on Object {
        // Session disposal is a final resource boundary; native process
        // shutdown remains the last fallback when the page is already gone.
      }
    }
    try {
      await _subtitleWindowHost.dispose();
    } on Object {
      // The child is display-only; the owning process shutdown is the fallback.
    }
  }

  Future<void> _disposeCaptureAndRecorder(LiveSubtitleSession? session) async {
    final screenCapture = widget.screenCapture;
    final cleanupSteps = <AppExitCleanup>[
      () => _stopScreenRecording(updateUi: false),
    ];
    if (screenCapture != null && (_screenRecording || _screenTarget != null)) {
      if (_screenRecording) {
        cleanupSteps.add(() async {
          await screenCapture.stopRecording();
        });
      }
      if (_screenTarget != null) cleanupSteps.add(screenCapture.stopCapture);
    }
    cleanupSteps.add(
      () => _stopAudioOnlyCapture(updateUi: false, finalizeRecording: false),
    );
    if (session != null && _sessionIsActive) {
      cleanupSteps.add(() async {
        await session.stop();
      });
    }
    cleanupSteps
      ..add(
        () => _finalizeAudioRecording(
          showFailure: false,
          captureStopUnconfirmedIfActive:
              session?.captureStopConfirmed == false,
        ),
      )
      ..add(_disposeAudioRecorder);
    try {
      await runExitCleanupSteps(cleanupSteps);
    } on Object {
      // Native window teardown also releases any capture resources that remain.
    }
  }

  Future<void> _disposeAudioRecorder() =>
      _audioRecorderDisposal.run(_audioRecorder.dispose);

  Completer<void> _beginTrackedOperation() {
    _exitPreparationSucceeded = false;
    final completion = Completer<void>();
    _trackedOperations.add(completion);
    return completion;
  }

  void _finishTrackedOperation(Completer<void> completion) {
    _trackedOperations.remove(completion);
    if (!completion.isCompleted) completion.complete();
    _resumeAfterCancelledExitWorkIfDrained();
  }

  void _resumeAfterCancelledExitWorkIfDrained() {
    if (!_cancelledExitWaitPending ||
        _trackedOperations.isNotEmpty ||
        _screenStopFuture != null ||
        _compactResizeFuture != null) {
      return;
    }
    _cancelledExitWaitPending = false;
    if (mounted) {
      setState(() {
        _operationInProgress = false;
        _operationLabel = null;
      });
    }
  }

  Future<void> _awaitExitWorkOrCancellation(
    Future<void> work,
    AppExitCleanupCancellation? cancellation,
  ) async {
    if (cancellation == null) return work;
    if (cancellation.isCancelled) {
      throw const AppExitCleanupCancelled();
    }
    await Future.any<void>([
      work,
      cancellation.whenCancelled.then<void>(
        (_) => throw const AppExitCleanupCancelled(),
      ),
    ]);
    if (cancellation.isCancelled) {
      throw const AppExitCleanupCancelled();
    }
  }

  Future<void> _waitForTrackedOperations({
    AppExitCleanupCancellation? cancellation,
  }) async {
    while (_trackedOperations.isNotEmpty ||
        _screenStopFuture != null ||
        _compactResizeFuture != null) {
      if (cancellation?.isCancelled ?? false) {
        throw const AppExitCleanupCancelled();
      }
      final pending = _trackedOperations
          .map((operation) => operation.future)
          .toList();
      final screenStop = _screenStopFuture;
      if (screenStop != null) pending.add(screenStop);
      final compactResize = _compactResizeFuture;
      if (compactResize != null) pending.add(compactResize);
      if (pending.isNotEmpty) {
        final waitForAll = Future.wait(
          pending.map((operation) async {
            try {
              await operation;
            } on Object {
              // The final exit cleanup retries native stop operations and
              // reports failures after attempting every remaining step.
            }
          }),
        );
        await _awaitExitWorkOrCancellation(waitForAll, cancellation);
      }
    }
  }

  Future<void> _runTrackedExitCleanupStep(AppExitCleanup step) async {
    final operation = _beginTrackedOperation();
    try {
      await step();
    } finally {
      _finishTrackedOperation(operation);
    }
  }

  Future<void> _prepareForAppExit() async {
    final cancellation = AppExitCleanupRegistry.activeCancellation;
    final pageDisposal = _pageResourcesDisposal;
    if (pageDisposal != null) {
      await _awaitExitWorkOrCancellation(pageDisposal, cancellation);
      _exitPreparationSucceeded = true;
      return;
    }
    _exitPreparationSucceeded = false;
    _compactWindowTransitionGeneration++;
    _isPreparingForAppExit = true;
    _cancelPendingSessionUiUpdate();
    if (mounted) setState(() {});
    _cancelModelDownload = true;
    _screenStatePollTimer?.cancel();
    _screenStatePollTimer = null;
    try {
      // Invalidate queued debounce callbacks before waiting on tracked work.
      // The user may cancel this exit wait; clearing the queue first prevents
      // a timer callback from resizing the window after that cancellation.
      await _cancelCompactResizesAndWait(cancellation: cancellation);
      await _waitForTrackedOperations(cancellation: cancellation);
    } on AppExitCleanupCancelled {
      _isPreparingForAppExit = false;
      _cancelledExitWaitPending =
          _trackedOperations.isNotEmpty ||
          _screenStopFuture != null ||
          _compactResizeFuture != null;
      if (mounted) {
        setState(() {
          _operationInProgress = _cancelledExitWaitPending;
          _operationLabel = _cancelledExitWaitPending
              ? '正在完成已启动的操作，稍后可继续'
              : null;
        });
      }
      _resumeAfterCancelledExitWorkIfDrained();
      return;
    } on Object {
      _isPreparingForAppExit = false;
      if (mounted) setState(() {});
      rethrow;
    }

    final screenCapture = widget.screenCapture;
    final session = _session;
    if (mounted) {
      setState(() {
        _operationInProgress = true;
        _operationLabel = '正在停止采集并保存字幕';
      });
    }

    final cleanupSteps = <AppExitCleanup>[];
    if (screenCapture != null) {
      if (_screenRecording) {
        cleanupSteps.add(() async {
          final path = await screenCapture.stopRecording();
          if (mounted) {
            setState(() {
              _screenRecording = false;
              _recordingPath = null;
              if (path != null && path.isNotEmpty) _lastRecordingPath = path;
            });
          }
        });
      }
      if (_screenTarget != null) {
        cleanupSteps.add(() async {
          await screenCapture.stopCapture();
          if (mounted) setState(() => _screenTarget = null);
        });
      }
    }
    cleanupSteps
      ..add(() => _stopScreenRecording(updateUi: false, throwOnFailure: true))
      ..add(
        () => _stopAudioOnlyCapture(
          updateUi: false,
          finalizeRecording: false,
          throwOnStopFailure: true,
        ),
      );
    if (session != null) {
      cleanupSteps.add(() async {
        // stop() is idempotent after a completed stop. For asynchronous
        // failure, it queues behind the session's failure cleanup and drains
        // persistence.
        await session.stop();
        _throwIfSubtitleSaveFailed(session);
      });
    }
    cleanupSteps.add(
      () => _finalizeAudioRecording(
        showFailure: false,
        throwOnFailure: true,
        captureStopUnconfirmedIfActive: session?.captureStopConfirmed == false,
      ),
    );
    cleanupSteps.add(() async {
      if (cancellation?.isCancelled ?? false) {
        throw const AppExitCleanupCancelled();
      }
      _cancelSubtitleWindowUpdate();
      await _subtitleWindowHost.hide();
      if (mounted) setState(() => _subtitleWindowVisible = false);
    });
    try {
      await runExitCleanupSteps(
        cleanupSteps.map(
          (step) =>
              () => _runTrackedExitCleanupStep(step),
        ),
        cancellation: cancellation,
      );
      // Dispose only after every exit cleanup step succeeds. If the user
      // cancels a failed exit and returns to the workbench, the recorder must
      // remain usable. The memoized wrapper also shares this operation with
      // the page-teardown fallback if those lifecycle paths overlap.
      await _disposeAudioRecorder();
      _exitPreparationSucceeded = true;
    } on AppExitCleanupCancelled {
      _cancelledExitWaitPending =
          _trackedOperations.isNotEmpty ||
          _screenStopFuture != null ||
          _compactResizeFuture != null;
      _resumeAfterCancelledExitWorkIfDrained();
    } finally {
      _isPreparingForAppExit = false;
      if (mounted) {
        setState(() {
          final pendingWork = _cancelledExitWaitPending;
          _operationInProgress = pendingWork;
          _operationLabel = pendingWork ? '正在完成已启动的操作，稍后可继续' : null;
          if (session != null) _sessionState = session.currentState;
        });
      }
    }
  }

  void _throwIfSubtitleSaveFailed(LiveSubtitleSession session) {
    if (session.currentState.persistence?.status ==
        SubtitleSessionSaveStatus.failed) {
      throw const LiveSubtitleSessionException('storage_close_failed');
    }
  }

  Future<void> _checkModelInstallation() async {
    final generation = ++_modelCheckGeneration;
    final sourceLanguageCode = _sourceLanguageCode;
    if (!_isDesktop) {
      if (!mounted) return;
      setState(() {
        _checkingModel = false;
        _modelInstalled = false;
        _modelErrorCode = 'desktop_only';
      });
      return;
    }
    setState(() {
      _checkingModel = true;
      _modelInstalled = null;
      _modelErrorCode = null;
    });
    try {
      final installed = _usesMultilingualModel(sourceLanguageCode)
          ? await widget.multilingualModelStore.isInstalled()
          : await widget.modelStore.isInstalled();
      if (!mounted || generation != _modelCheckGeneration) return;
      setState(() {
        _modelInstalled = installed;
        _checkingModel = false;
      });
    } catch (_) {
      if (!mounted || generation != _modelCheckGeneration) return;
      setState(() {
        _modelInstalled = false;
        _checkingModel = false;
        _modelErrorCode = 'model_check_failed';
      });
    }
  }

  Future<void> _downloadModel() async {
    if (_downloadingModel || !_isDesktop) return;
    final sourceLanguageCode = _sourceLanguageCode;
    final usesMultilingualModel = _usesMultilingualModel(sourceLanguageCode);
    final operation = _beginTrackedOperation();
    setState(() {
      _downloadingModel = true;
      _cancelModelDownload = false;
      _modelErrorCode = null;
      _modelDownloadProgress = null;
    });
    try {
      final download = usesMultilingualModel
          ? widget.multilingualModelStore.downloadAndInstall
          : widget.modelStore.downloadAndInstall;
      await download(
        shouldCancel: () => _cancelModelDownload,
        onProgress: (progress) {
          if (!mounted) return;
          setState(() => _modelDownloadProgress = progress);
        },
      );
      if (!mounted) return;
      setState(() {
        _modelInstalled = true;
        _modelErrorCode = null;
      });
    } on StreamingAsrModelStoreException catch (error) {
      if (!mounted) return;
      setState(() {
        _modelInstalled = false;
        _modelErrorCode = error.code;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _modelInstalled = false;
        _modelErrorCode = 'model_download_failed';
      });
    } finally {
      if (mounted) {
        setState(() {
          _downloadingModel = false;
          _modelDownloadProgress = null;
        });
      }
      _finishTrackedOperation(operation);
    }
  }

  Future<void> _refreshSources() async {
    if (!_isDesktop || _loadingSources) return;
    setState(() {
      _loadingSources = true;
      _sourceLoadError = null;
    });
    try {
      final enumeratedSources = await widget.capture.enumerateSources();
      final sources = enumeratedSources
          .where(
            (source) =>
                source.sourceKind == SubtitleAudioSourceKind.systemOutput,
          )
          .toList(growable: false);
      final microphones = enumeratedSources
          .where(
            (source) => source.sourceKind == SubtitleAudioSourceKind.microphone,
          )
          .toList(growable: false);
      if (!mounted) return;
      final previousId = _selectedSourceId;
      final selected = sources.any((source) => source.sourceId == previousId)
          ? previousId
          : (sources.isEmpty ? null : sources.first.sourceId);
      final previousMicrophoneId = _selectedMicrophoneSourceId;
      final selectedMicrophone =
          microphones.any((source) => source.sourceId == previousMicrophoneId)
          ? previousMicrophoneId
          : (microphones.isEmpty ? null : microphones.first.sourceId);
      setState(() {
        _sources = sources;
        _microphoneSources = microphones;
        _selectedSourceId = selected;
        _selectedMicrophoneSourceId = selectedMicrophone;
        _loadingSources = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _sources = const [];
        _microphoneSources = const [];
        _selectedSourceId = null;
        _selectedMicrophoneSourceId = null;
        _loadingSources = false;
        _sourceLoadError = '无法读取桌面系统音源，请确认当前平台支持并重试。';
      });
    }
  }

  Future<void> _loadRecentSessions() async {
    try {
      final sessions = await widget.sessionStore.listSessions();
      if (!mounted) return;
      setState(() => _recentSessions = sessions.take(4).toList());
    } catch (_) {
      if (mounted) setState(() => _recentSessions = const []);
    }
  }

  Future<void> _checkScreenCaptureSupport() async {
    final adapter = widget.screenCapture;
    if (adapter == null || _screenCaptureChecking) return;
    if (mounted) {
      setState(() {
        _screenCaptureChecking = true;
        _screenCaptureSupported = null;
        _screenCaptureError = null;
      });
    }
    try {
      final supported = await adapter.isSupported();
      if (!mounted) return;
      setState(() {
        _screenCaptureSupported = supported;
        _screenCaptureError = supported ? null : '此 Windows 版本不支持桌面画面采集。';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        // A failed probe is not the same as a Windows version that reports
        // Graphics Capture as unsupported. Keep the distinction so the user
        // can retry a transient channel or native initialization failure.
        _screenCaptureSupported = null;
        _screenCaptureError = _screenCaptureInitializationError(error);
      });
    } finally {
      if (mounted) setState(() => _screenCaptureChecking = false);
    }
  }

  String _screenCaptureInitializationError(Object error) {
    if (error is MissingPluginException) {
      final detail = error.message?.trim();
      return detail == null || detail.isEmpty
          ? 'Windows 桌面采集组件未注册。可重新检测，或继续音频同传（不含画面）。'
          : 'Windows 桌面采集组件未注册（${_safeScreenError(detail)}）。'
                '可重新检测，或继续音频同传（不含画面）。';
    }
    if (error is PlatformException) {
      final detail = [
        error.code,
        if (error.message?.trim().isNotEmpty ?? false) error.message!.trim(),
      ].join('：');
      return 'Windows 桌面画面采集初始化失败（${_safeScreenError(detail)}）。'
          '可重新检测，或继续音频同传（不含画面）。';
    }
    return 'Windows 桌面画面采集初始化失败（${_safeScreenError(error)}）。'
        '可重新检测，或继续音频同传（不含画面）。';
  }

  void _onScreenCaptureEvent(DesktopScreenCaptureEvent event) {
    if (!mounted) return;
    final screenCapture = widget.screenCapture;
    if (screenCapture != null &&
        (!screenCapture.isCurrentCaptureEvent(event) ||
            !screenCapture.isCurrentRecordingEvent(event))) {
      return;
    }
    if (event.type == 'size' &&
        event.width != null &&
        event.height != null &&
        _screenTarget != null) {
      setState(() {
        _screenTarget = DesktopScreenCaptureTarget(
          textureId: _screenTarget!.textureId,
          width: event.width!,
          height: event.height!,
          targetName: _screenTarget!.targetName,
        );
      });
      return;
    }
    if (event.type != 'state') return;
    if (event.status == 'recordingAudioFailed') {
      setState(() {
        _screenRecording = false;
        _recordingPath = null;
        _screenCaptureError = '系统声音采集失败，录屏已停止。';
      });
      unawaited(_finalizeRecordingAfterNativeFailure());
      return;
    }
    if (event.status == 'recordingFinalized' &&
        event.detail != null &&
        event.detail!.isNotEmpty) {
      setState(() {
        _screenRecording = false;
        _recordingPath = null;
        _lastRecordingPath = event.detail;
      });
      return;
    }
    if (event.status == 'captureStopped' ||
        event.status == 'captureFailed' ||
        event.errorCode == 'captureTargetClosed') {
      setState(() {
        _screenTarget = null;
        _screenRecording = false;
        _recordingPath = null;
        _screenCaptureError =
            event.detail ??
            (event.errorCode == 'captureTargetClosed'
                ? '所选窗口或屏幕已关闭，采集已经停止。'
                : null);
      });
      return;
    }
    if (event.status == 'recordingFailed') {
      setState(() {
        _screenRecording = false;
        _recordingPath = null;
        _screenCaptureError = event.detail ?? 'MP4 录制失败。';
      });
    }
  }

  Future<void> _finalizeRecordingAfterNativeFailure() async {
    if (_isPreparingForAppExit) return;
    final adapter = widget.screenCapture;
    if (adapter == null) return;
    final operation = _beginTrackedOperation();
    try {
      final path = await adapter.stopRecording();
      if (!mounted || path == null || path.isEmpty) return;
      setState(() => _lastRecordingPath = path);
    } catch (_) {
      // The native worker already reports why it stopped; keep the page usable.
    } finally {
      _finishTrackedOperation(operation);
    }
  }

  Future<void> _selectDesktopCaptureTarget() async {
    final adapter = widget.screenCapture;
    if (_isPreparingForAppExit ||
        adapter == null ||
        _screenCaptureBusy ||
        _screenRecording) {
      return;
    }
    final operation = _beginTrackedOperation();
    setState(() {
      _screenCaptureBusy = true;
      _screenCaptureError = null;
    });
    try {
      final target = await adapter.selectSource();
      if (!mounted) return;
      setState(() {
        _screenTarget = target;
        _screenCaptureBusy = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _screenCaptureBusy = false;
        _screenCaptureError = error.toString();
      });
    } finally {
      _finishTrackedOperation(operation);
    }
  }

  Future<void> _startDesktopRecording() async {
    final adapter = widget.screenCapture;
    if (_isPreparingForAppExit ||
        adapter == null ||
        _screenTarget == null ||
        _screenCaptureBusy ||
        _operationInProgress ||
        _screenRecording) {
      return;
    }
    final operation = _beginTrackedOperation();
    setState(() {
      _screenCaptureBusy = true;
      _screenCaptureError = null;
    });
    try {
      final path = await adapter.startRecording(
        // The legacy screen-capture card is still available for existing
        // workflows. Reuse the active subtitle session ID so the MP4 index can
        // attach this recording to its transcript history entry.
        sessionId: _sessionIsActive
            ? _sessionState?.coordinator?.sessionId
            : null,
        captureAttemptId: 'screen-capture-${widget.idFactory()}',
      );
      if (!mounted) return;
      setState(() {
        _screenRecording = true;
        _recordingPath = path;
        _lastRecordingPath = null;
        _screenCaptureBusy = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _screenCaptureBusy = false;
        _screenCaptureError = error.toString();
      });
    } finally {
      _finishTrackedOperation(operation);
    }
  }

  Future<void> _stopDesktopRecording() async {
    final adapter = widget.screenCapture;
    if (_isPreparingForAppExit ||
        adapter == null ||
        !_screenRecording ||
        _screenCaptureBusy) {
      return;
    }
    final operation = _beginTrackedOperation();
    setState(() => _screenCaptureBusy = true);
    try {
      final path = await adapter.stopRecording();
      if (!mounted) return;
      setState(() {
        _screenRecording = false;
        _recordingPath = null;
        _lastRecordingPath = path;
        _screenCaptureBusy = false;
      });
      if (path != null && path.isNotEmpty) {
        _showMessage(
          adapter.lastRecordingAudioFinalized
              ? '录屏已保存到本机。'
              : '视频已保存，但系统声音未能确认结束，音轨可能不完整。',
        );
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _screenCaptureBusy = false;
        _screenCaptureError = error.toString();
      });
    } finally {
      _finishTrackedOperation(operation);
    }
  }

  Future<void> _stopDesktopScreenCapture() async {
    final adapter = widget.screenCapture;
    if (_isPreparingForAppExit ||
        adapter == null ||
        _screenCaptureBusy ||
        (!_screenRecording && _screenTarget == null)) {
      return;
    }
    final operation = _beginTrackedOperation();
    setState(() => _screenCaptureBusy = true);
    try {
      String? path;
      final cleanupSteps = <AppExitCleanup>[];
      if (_screenRecording) {
        cleanupSteps.add(() async {
          path = await adapter.stopRecording();
          if (mounted) {
            setState(() {
              _screenRecording = false;
              _recordingPath = null;
              if (path?.isNotEmpty == true) _lastRecordingPath = path;
            });
          }
        });
      }
      if (_screenTarget != null) {
        cleanupSteps.add(() async {
          await adapter.stopCapture();
          if (mounted) setState(() => _screenTarget = null);
        });
      }
      await runExitCleanupSteps(cleanupSteps);
      if (mounted) {
        setState(() => _screenCaptureBusy = false);
        if (path?.isNotEmpty == true) {
          _showMessage(
            adapter.lastRecordingAudioFinalized
                ? '录屏已保存到本机。'
                : '视频已保存，但系统声音未能确认结束，音轨可能不完整。',
          );
        }
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _screenCaptureBusy = false;
        _screenCaptureError = error.toString();
      });
    } finally {
      _finishTrackedOperation(operation);
    }
  }

  Future<void> _loadTranslationSetup() async {
    final generation = ++_routeLoadGeneration;
    setState(() {
      _loadingTranslationSetup = true;
      _translationSetupError = null;
    });
    try {
      final setup = await _resolveTranslationSetup(
        sourceLanguageCode: _sourceLanguageCode,
        targetLanguageCode: _targetLanguageCode,
      );
      if (!mounted || generation != _routeLoadGeneration) return;
      setState(() {
        _translationSetup = setup;
        _loadingTranslationSetup = false;
      });
    } catch (_) {
      if (!mounted || generation != _routeLoadGeneration) return;
      setState(() {
        _translationSetup = null;
        _loadingTranslationSetup = false;
        _translationSetupError = '无法读取当前字幕翻译 Provider 配置。';
      });
    }
  }

  Future<LiveSubtitleTranslationSetup> _resolveTranslationSetup({
    required String sourceLanguageCode,
    required String targetLanguageCode,
  }) async {
    final targetLanguage = AsrLanguageRegistry.languageForCode(
      targetLanguageCode,
    );
    if (targetLanguage == null) {
      return _unavailableTranslationSetup('请选择支持的具体译文语言。');
    }

    if (sourceLanguageCode != 'auto') {
      if (!AsrLanguageRegistry.isSupportedCode(sourceLanguageCode) ||
          AsrLanguageRegistry.normalizeCode(sourceLanguageCode) ==
              targetLanguage.code) {
        return _unavailableTranslationSetup('原文和译文需要是不同的支持语言。');
      }
      return widget.translationSetupLoader(
        sourceLanguageCodes: <String>[sourceLanguageCode],
        targetLanguageCode: targetLanguage.code,
      );
    }

    // Auto is an ASR mode, never a translation language. Resolve every
    // possible non-identical source in one loader call so the caller can use
    // one consistent provider snapshot and keep usable directions available
    // when another direction has no route.
    final possibleSources = AsrLanguageRegistry.supportedLanguages
        .where((language) => language.code != targetLanguage.code)
        .toList(growable: false);
    if (possibleSources.isEmpty) {
      return _unavailableTranslationSetup('当前译文语言没有可用的原文方向。');
    }
    return widget.translationSetupLoader(
      sourceLanguageCodes: possibleSources
          .map((source) => source.code)
          .toList(growable: false),
      targetLanguageCode: targetLanguage.code,
    );
  }

  LiveSubtitleTranslationSetup _unavailableTranslationSetup(String detail) =>
      LiveSubtitleTranslationSetup(
        executor: const _DisabledSubtitleTranslationExecutor(),
        routeKind: SubtitleTranslationRouteKind.unavailable,
        providerLabel: '不可用',
        detail: detail,
      );

  void _changeLanguages({required String source, required String target}) {
    String? selectionNotice;
    final supportedTargets = TranslationDirection.targetLanguageCodesForSource(
      source,
    );
    if (supportedTargets.isEmpty) {
      _showMessage('该原文语种暂时没有可用的翻译方向。');
      return;
    }
    if (!supportedTargets.contains(target)) {
      final fallbackTarget = supportedTargets.first;
      selectionNotice =
          '当前语种组合暂不支持${_languageName(target)}，目标语已切换为${_languageName(fallbackTarget)}。';
      target = fallbackTarget;
    }
    if (source == target ||
        target == 'auto' ||
        _sessionIsActive ||
        _operationInProgress ||
        _changingLanguages) {
      return;
    }
    unawaited(
      _applyLanguageChange(
        source: source,
        target: target,
        selectionNotice: selectionNotice,
      ),
    );
  }

  Future<void> _applyLanguageChange({
    required String source,
    required String target,
    String? selectionNotice,
  }) async {
    final generation = ++_languageChangeGeneration;
    setState(() {
      _changingLanguages = true;
      _translationSetupError = null;
    });
    LiveSubtitleTranslationSetup? setup;
    try {
      if (_translationEnabled) {
        setup = await _resolveTranslationSetup(
          sourceLanguageCode: source,
          targetLanguageCode: target,
        );
        if (setup.routeKind == SubtitleTranslationRouteKind.unavailable) {
          if (mounted && generation == _languageChangeGeneration) {
            _showMessage(setup.detail ?? '此语言方向没有已配置的 Provider。');
          }
          return;
        }
      }
      if (!mounted || generation != _languageChangeGeneration) return;
      setState(() {
        _sourceLanguageCode = source;
        _targetLanguageCode = target;
        _translationSetup = setup;
        _loadingTranslationSetup = false;
        _modelInstalled = null;
      });
      unawaited(_checkModelInstallation());
      if (selectionNotice != null) _showMessage(selectionNotice);
    } catch (_) {
      if (mounted && generation == _languageChangeGeneration) {
        _showMessage('无法确认该语言方向的 Provider，语言选择未更改。');
      }
    } finally {
      if (mounted && generation == _languageChangeGeneration) {
        setState(() => _changingLanguages = false);
      }
    }
  }

  Future<void> _startSession() async {
    if (_screenStopFuture != null) {
      _showMessage('正在完成上一段录屏的收尾，请稍候再开始同传。');
      return;
    }
    if (_screenRecording ||
        _screenRecordingActive ||
        _screenRecordingOperationInProgress) {
      _showMessage('当前录屏独立占用音源。若要边同传边录屏，请先停止并保存这段录屏，开始同传后再启动录屏。');
      return;
    }
    if (!canStartAudioCaptureAfterScreenRecordingCleanup(
      _screenRecordingCleanupStatus,
      screenRecordingStopInProgress: _screenStopFuture != null,
      audioSubscriptionCleanupUnconfirmed:
          _screenAudioFrameSubscription != null,
    )) {
      _showMessage('上一段录屏的音源尚未确认停止。请先重试停止录屏，再开始同传。');
      return;
    }
    if (!_canStart) return;
    final sources = _selectedCaptureSources;
    if (sources.isEmpty) return;
    final primarySource = sources.first;
    final sessionId = widget.idFactory();
    _diagnosticSessionId = sessionId;

    final operation = _beginTrackedOperation();
    setState(() {
      _operationInProgress = true;
      _operationLabel = '正在准备字幕会话';
      _operationErrorCode = null;
    });
    try {
      var setup = _translationSetup;
      SubtitleTranslationExecutor executor =
          const _DisabledSubtitleTranslationExecutor();
      if (_translationEnabled) {
        // Resolve the Provider again at the user's start action. The returned
        // executor and its display metadata must come from the same frozen route.
        setup = await _runSubtitleDiagnosticPhase<LiveSubtitleTranslationSetup>(
          sessionId: sessionId,
          phase: 'translation_route',
          operation: () => _resolveTranslationSetup(
            sourceLanguageCode: _sourceLanguageCode,
            targetLanguageCode: _targetLanguageCode,
          ),
        );
        if (!mounted) return;
        setState(() => _translationSetup = setup);
        if (setup.routeKind == SubtitleTranslationRouteKind.unavailable) {
          throw const _WorkbenchFailure('translation_route_unavailable');
        }
        if (setup.routeKind == SubtitleTranslationRouteKind.remoteProfile) {
          final confirmed = await _confirmRemoteTranslation(setup);
          if (!confirmed || !mounted) return;
        }
        executor = setup.executor;

        if (_sourceLanguageCode != 'auto' &&
            setup.routeKind != SubtitleTranslationRouteKind.remoteProfile &&
            executor is SubtitleTranslationPreparer) {
          final preparer = executor as SubtitleTranslationPreparer;
          setState(() => _operationLabel = '正在预热本地翻译模型');
          try {
            await _runSubtitleDiagnosticPhase<void>(
              sessionId: sessionId,
              phase: 'translation_model_warmup',
              operation: () => preparer.prepareForDirection(
                sourceLanguageCode: _sourceLanguageCode,
                targetLanguageCode: _targetLanguageCode,
              ),
            );
          } catch (_) {
            // A failed warm-up must not prevent audio capture and recognition.
            // The normal translation request will surface its own error.
            if (mounted) {
              _showMessage('本地翻译模型预热未完成；同传会继续，首条译文可能较慢。');
            }
          }
          if (!mounted) return;
        }
      }

      final oldSubscription = _sessionSubscription;
      _sessionSubscription = null;
      if (oldSubscription != null) await oldSubscription.cancel();
      final previousSession = _session;
      if (previousSession != null) await previousSession.dispose();

      final initialCaptureAttemptId = 'capture-${widget.idFactory()}';
      final session = LiveSubtitleSession(
        capture: widget.capture,
        asrRuntime: widget.asrRuntime,
        store: widget.sessionStore,
        translationExecutor: executor,
        onCaptureAttemptChanged: _audioRecorder.setCaptureAttemptId,
      );
      _session = session;
      _sessionState = session.currentState;
      _sessionSubscription = session.stateChanges.listen(
        (state) {
          if (!mounted || !identical(_session, session)) return;
          _queueSessionUiUpdate(session, state);
        },
        onError: (_) {
          if (!mounted || !identical(_session, session)) return;
          setState(() => _operationErrorCode = 'session_state_stream_failed');
        },
      );

      setState(() {
        _operationLabel = '正在启动采集与识别';
      });
      var audioRecordingStartFailed = false;
      if (_retainSessionAudio) {
        try {
          await _runSubtitleDiagnosticPhase<void>(
            sessionId: sessionId,
            phase: 'audio_recording_start',
            operation: () => _audioRecorder.start(
              sessionId: sessionId,
              captureAttemptId: initialCaptureAttemptId,
              sources: sources
                  .map(
                    (source) => SubtitleSessionAudioSource(
                      sourceId: source.sourceId,
                      sourceKind: source.sourceKind,
                      displayName: source.displayName,
                    ),
                  )
                  .toList(growable: false),
              frames: widget.capture.frames,
            ),
          );
          if (mounted) {
            setState(() => _audioRecordingState = _audioRecorder.state);
          }
        } on Object {
          // Audio retention is optional and must not prevent live recognition
          // from starting when the recording folder or WAV writer is unavailable.
          audioRecordingStartFailed = true;
          if (mounted) {
            setState(() => _audioRecordingState = _audioRecorder.state);
          }
        }
      }
      await _runSubtitleDiagnosticPhase<void>(
        sessionId: sessionId,
        phase: 'capture_asr_start',
        operation: () => session.start(
          LiveSubtitleSessionStartRequest(
            sessionId: sessionId,
            initialCaptureAttemptId: initialCaptureAttemptId,
            source: primarySource,
            additionalSources: sources.skip(1),
            kind: _sessionKind,
            sourceLanguageCode: _sourceLanguageCode,
            targetLanguageCode: _targetLanguageCode,
            translationEnabled: _translationEnabled,
            startedAtUtc: widget.clock().toUtc(),
          ),
        ),
      );
      if (mounted && identical(_session, session) && _sessionIsActive) {
        // Open the display process only after capture/ASR startup succeeds.
        // The subtitle window is display-only, so its startup must not hold up
        // the live session or turn a window failure into a session failure.
        unawaited(
          _runSubtitleDiagnosticPhase<void>(
            sessionId: sessionId,
            phase: 'subtitle_window_open',
            operation: () => _setSubtitleWindowVisible(true),
          ),
        );
      }
      if (audioRecordingStartFailed && mounted) {
        _showMessage('音频留存未能启动；同传已继续，本次会话不会保存音频。');
      }
    } on LiveSubtitleSessionException catch (error) {
      _setStartError(error.code);
    } on _WorkbenchFailure catch (error) {
      _setStartError(error.code);
    } catch (_) {
      _setStartError('session_start_failed');
    } finally {
      try {
        final currentSession = _session;
        final currentStatus = currentSession?.currentState.coordinator?.status;
        final currentSessionIsActive = switch (currentStatus) {
          SubtitleSessionStatus.preparing ||
          SubtitleSessionStatus.capturing ||
          SubtitleSessionStatus.paused ||
          SubtitleSessionStatus.stopping => true,
          SubtitleSessionStatus.idle ||
          SubtitleSessionStatus.stopped ||
          SubtitleSessionStatus.failed ||
          null => false,
        };
        if (currentSession != null && !currentSessionIsActive) {
          await _finalizeAudioRecording(
            showFailure: true,
            captureStopUnconfirmedIfActive:
                !currentSession.captureStopConfirmed,
          );
          final currentSubscription = _sessionSubscription;
          _sessionSubscription = null;
          if (currentSubscription != null) {
            try {
              await currentSubscription.cancel();
            } on Object {
              // Cleanup continues even if a state-stream subscription fails.
            }
          }
          try {
            await currentSession.dispose();
          } on Object catch (error) {
            if (mounted) _showMessage('同传会话资源收尾失败：${_safeScreenError(error)}');
          }
          _sessionState = currentSession.currentState;
        }
      } on Object catch (error) {
        if (mounted) _showMessage('同传启动后的收尾遇到问题：${_safeScreenError(error)}');
      } finally {
        try {
          if (mounted) {
            setState(() {
              _operationInProgress = false;
              _operationLabel = null;
              _sessionState = _session?.currentState ?? _sessionState;
            });
          }
        } finally {
          _finishTrackedOperation(operation);
        }
      }
    }
  }

  Future<T> _runSubtitleDiagnosticPhase<T>({
    required String sessionId,
    required String phase,
    required Future<T> Function() operation,
  }) async {
    final stopwatch = Stopwatch()..start();
    await AppExitCleanupRegistry.recordSubtitleSessionPhase(
      sessionId: sessionId,
      phase: phase,
      status: 'begin',
    );
    try {
      final result = await operation();
      await AppExitCleanupRegistry.recordSubtitleSessionPhase(
        sessionId: sessionId,
        phase: phase,
        status: 'success',
        elapsedMilliseconds: stopwatch.elapsedMilliseconds,
      );
      return result;
    } on Object catch (error) {
      final errorCode = switch (error) {
        LiveSubtitleSessionException(:final code) => code,
        _WorkbenchFailure(:final code) => code,
        _ => 'operation_failed',
      };
      await AppExitCleanupRegistry.recordSubtitleSessionPhase(
        sessionId: sessionId,
        phase: phase,
        status: 'failure',
        elapsedMilliseconds: stopwatch.elapsedMilliseconds,
        errorCode: errorCode,
        errorType: error.runtimeType.toString(),
      );
      rethrow;
    }
  }

  Future<void> _startAudioOnlyRecording() async {
    if (!canStartAudioCaptureAfterScreenRecordingCleanup(
      _screenRecordingCleanupStatus,
      screenRecordingStopInProgress: _screenStopFuture != null,
      audioSubscriptionCleanupUnconfirmed:
          _screenAudioFrameSubscription != null,
    )) {
      _showMessage('上一段录屏的音源尚未确认停止。请先重试停止录屏，再开始录音。');
      return;
    }
    if (!_canStartAudioOnly) return;
    final sources = _selectedCaptureSources;
    if (sources.isEmpty) return;

    final sessionId = 'audio-only-${widget.idFactory()}';
    final captureAttemptId = 'capture-${widget.idFactory()}';
    final operation = _beginTrackedOperation();
    setState(() {
      _operationInProgress = true;
      _operationLabel = '正在启动独立音频录制';
      _operationErrorCode = null;
      _audioOnlySessionId = sessionId;
      _audioOnlyCaptureAttemptId = captureAttemptId;
      _audioOnlySources = const [];
      _audioOnlySourceStates.clear();
    });

    try {
      await _audioOnlySourceSubscription?.cancel();
      _audioOnlySourceSubscription = widget.capture.sourceStates.listen(
        (state) {
          if (!mounted ||
              state.sessionId != _audioOnlySessionId ||
              state.captureAttemptId != _audioOnlyCaptureAttemptId) {
            return;
          }
          setState(() {
            _audioOnlySourceStates[_audioOnlySourceIdentity(
                  state.sourceKind,
                  state.sourceId,
                )] =
                state;
          });
        },
        onError: (_) {
          if (mounted) _showMessage('独立录音的音源状态通道中断；请检查本次录制文件。');
        },
      );

      await _audioRecorder.start(
        sessionId: sessionId,
        captureAttemptId: captureAttemptId,
        sources: sources
            .map(
              (source) => SubtitleSessionAudioSource(
                sourceId: source.sourceId,
                sourceKind: source.sourceKind,
                displayName: source.displayName,
              ),
            )
            .toList(growable: false),
        frames: widget.capture.frames,
      );
      if (mounted) {
        setState(() => _audioRecordingState = _audioRecorder.state);
      }

      for (final source in sources) {
        // A native start may have succeeded even if its response failed, so
        // include the current source in rollback before awaiting the call.
        _audioOnlySources = List<DesktopAudioCaptureSource>.unmodifiable([
          ..._audioOnlySources,
          source,
        ]);
        await widget.capture.startSource(
          source: source,
          sessionId: sessionId,
          captureAttemptId: captureAttemptId,
        );
      }

      if (mounted) {
        setState(() {
          _audioOnlyRecordingActive = true;
          _operationLabel = null;
        });
        _showMessage('独立录音已启动；不需要下载 ASR 模型，也不会生成字幕。');
      }
    } on Object {
      final stopResult = await stopCaptureSources<DesktopAudioCaptureSource>(
        _audioOnlySources,
        (source) => widget.capture.stopSource(
          sourceId: source.sourceId,
          sessionId: sessionId,
        ),
      );
      // Keep the attempted session and capture IDs while any source stop is
      // uncertain. The visible Stop action must be able to retry this exact
      // native ownership request instead of orphaning the capture.
      _audioOnlySources = stopResult.failedSources;
      final recorderState = _audioRecorder.state;
      final recordingWasActive =
          recorderState.status == SubtitleAudioRecordingStatus.recording ||
          recorderState.status == SubtitleAudioRecordingStatus.stopping ||
          (recorderState.status == SubtitleAudioRecordingStatus.failed &&
              !_audioRecorder.canStart);
      var recordingFinalized = _audioRecorder.canStart;
      if (stopResult.allStopped) {
        try {
          final stopped = await _audioRecorder.stop(
            failureReason: recordingWasActive
                ? 'audio_capture_start_failed'
                : null,
          );
          if (mounted) setState(() => _audioRecordingState = stopped);
          recordingFinalized =
              stopped.status == SubtitleAudioRecordingStatus.stopped ||
              stopped.status == SubtitleAudioRecordingStatus.failed ||
              stopped.status == SubtitleAudioRecordingStatus.idle;
        } on Object {
          // Preserve the source-start error shown below.
          recordingFinalized = false;
        }
        await _audioOnlySourceSubscription?.cancel();
        _audioOnlySourceSubscription = null;
      }
      if (mounted) {
        setState(() {
          _audioOnlyRecordingActive = !stopResult.allStopped;
          if (stopResult.allStopped) {
            _audioOnlySessionId = null;
            _audioOnlyCaptureAttemptId = null;
            _audioOnlySources = const [];
          }
        });
        var message = '独立录音启动中断，仍有音源未能确认停止。请点击“停止并保存独立录音”重试；确认停止前不会封存 WAV。';
        if (stopResult.allStopped) {
          if (!recordingFinalized) {
            message = '独立录音启动失败，音源已停止，但文件收尾失败；请检查录音目录中的恢复清单。';
          } else if (recordingWasActive) {
            message = '独立录音未能完整启动；已写入的 WAV 会按不完整记录保留在本机历史中。';
          } else {
            message = '无法启动独立录音；已停止已尝试的音源并完成资源收尾。';
          }
        }
        _showMessage(message);
      }
    } finally {
      if (mounted) {
        setState(() {
          _operationInProgress = false;
          _operationLabel = null;
        });
      }
      _finishTrackedOperation(operation);
    }
  }

  Future<void> _stopAudioOnlyRecording() async {
    if (!_audioOnlyRecordingActive || _operationInProgress) return;
    final operation = _beginTrackedOperation();
    setState(() {
      _operationInProgress = true;
      _operationLabel = '正在停止独立录音并完成 WAV';
    });
    try {
      await _stopAudioOnlyCapture(updateUi: true);
    } finally {
      if (mounted) {
        setState(() {
          _operationInProgress = false;
          _operationLabel = null;
        });
      }
      _finishTrackedOperation(operation);
    }
  }

  Future<void> _stopAudioOnlyCapture({
    required bool updateUi,
    bool finalizeRecording = true,
    bool throwOnStopFailure = false,
  }) async {
    final sources = List<DesktopAudioCaptureSource>.of(_audioOnlySources);
    final sessionId = _audioOnlySessionId;
    final stopResult = sessionId == null
        ? AudioCaptureStopResult<DesktopAudioCaptureSource>(
            stoppedSources: const [],
            failedSources: sources,
          )
        : await stopCaptureSources<DesktopAudioCaptureSource>(
            sources,
            (source) => widget.capture.stopSource(
              sourceId: source.sourceId,
              sessionId: sessionId,
            ),
          );

    var recordingFinalized = !finalizeRecording;
    // Keep the WAV writer and source-state subscription alive when any native
    // source may still be feeding it. The UI keeps a retryable Stop action.
    if (stopResult.allStopped && finalizeRecording) {
      try {
        final result = await _audioRecorder.stop();
        if (mounted) setState(() => _audioRecordingState = result);
        recordingFinalized =
            result.status == SubtitleAudioRecordingStatus.stopped;
      } on Object {
        recordingFinalized = false;
      }
    }

    if (stopResult.allStopped) {
      await _audioOnlySourceSubscription?.cancel();
      _audioOnlySourceSubscription = null;
    }
    if (mounted) {
      setState(() {
        _audioOnlyRecordingActive = !stopResult.allStopped;
        _audioOnlySources = stopResult.failedSources;
        if (stopResult.allStopped) {
          _audioOnlySessionId = null;
          _audioOnlyCaptureAttemptId = null;
        }
      });
      if (updateUi && !stopResult.allStopped) {
        _showMessage('部分音源未能确认停止；录音仍保持打开，可再次停止。确认全部停止前不会封存 WAV。');
      } else if (updateUi && !recordingFinalized) {
        _showMessage('音源已停止，但录音文件收尾失败；请检查录音目录中的恢复清单。');
      } else if (updateUi && stopResult.allStopped) {
        _showMessage('独立录音已保存到本机。');
      }
    }
    if (throwOnStopFailure && !stopResult.allStopped) {
      throw StateError(
        '${stopResult.failedSources.length} audio source(s) could not be confirmed stopped.',
      );
    }
  }

  String _audioOnlySourceIdentity(
    SubtitleAudioSourceKind sourceKind,
    String sourceId,
  ) => '${sourceKind.name}\u0000$sourceId';

  void _setStartError(String code) {
    if (!mounted) return;
    setState(() => _operationErrorCode = code);
    _showMessage(_friendlyError(code));
  }

  Future<bool> _confirmRemoteTranslation(
    LiveSubtitleTranslationSetup setup,
  ) async {
    final destination = setup.remoteDestinationLabel?.trim();
    final target = destination == null || destination.isEmpty
        ? setup.providerLabel
        : '${setup.providerLabel}（$destination）';
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('确认本次使用远程翻译'),
            content: Text(
              '本会话只会把已确认的字幕文本发送给 $target 进行翻译。'
              '${setup.detail == null ? '' : '\n\n${setup.detail}'}\n\n'
              'ASR 音频处理由当前注入的识别运行时负责；此提示说明的是翻译 Provider 的数据去向。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('返回'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('同意并开始'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _pauseSession() => _runSessionOperation(
    label: '正在暂停并收尾当前识别片段',
    operation: (session) => session.pause(),
    fallback: 'session_pause_failed',
  );

  Future<void> _resumeSession() => _runSessionOperation(
    label: '正在重新连接音源',
    operation: (session) => session.resume(),
    fallback: 'session_resume_failed',
  );

  Future<void> _stopSession() => _runSessionOperation(
    label: '正在停止并保存字幕',
    operation: (session) => session.stop(),
    fallback: 'session_stop_failed',
    finalizeAudioRecording: true,
  );

  Future<void> _runSessionOperation({
    required String label,
    required Future<void> Function(LiveSubtitleSession session) operation,
    required String fallback,
    bool finalizeAudioRecording = false,
  }) async {
    final session = _session;
    if (session == null || _operationInProgress) return;
    final trackedOperation = _beginTrackedOperation();
    setState(() {
      _operationInProgress = true;
      _operationLabel = label;
      _operationErrorCode = null;
    });
    try {
      final diagnosticSessionId = _diagnosticSessionId;
      final diagnosticPhase = switch (fallback) {
        'session_pause_failed' => 'session_pause',
        'session_resume_failed' => 'session_resume',
        _ => 'session_stop',
      };
      if (diagnosticSessionId == null) {
        await operation(session);
      } else {
        await _runSubtitleDiagnosticPhase<void>(
          sessionId: diagnosticSessionId,
          phase: diagnosticPhase,
          operation: () => operation(session),
        );
      }
    } on LiveSubtitleSessionException catch (error) {
      if (mounted) {
        setState(() => _operationErrorCode = error.code);
        _showMessage(_friendlyError(error.code));
      }
    } catch (_) {
      if (mounted) {
        setState(() => _operationErrorCode = fallback);
        _showMessage(_friendlyError(fallback));
      }
    } finally {
      try {
        if (finalizeAudioRecording) {
          await _finalizeAudioRecording(
            showFailure: true,
            captureStopUnconfirmedIfActive: !session.captureStopConfirmed,
          );
        }
      } on Object catch (error) {
        if (mounted) _showMessage('同传停止后的收尾遇到问题：${_safeScreenError(error)}');
      } finally {
        try {
          if (mounted) {
            setState(() {
              _operationInProgress = false;
              _operationLabel = null;
              _sessionState = session.currentState;
            });
          }
        } finally {
          if (finalizeAudioRecording) {
            unawaited(_loadRecentSessions().catchError((Object _) {}));
          }
          _finishTrackedOperation(trackedOperation);
        }
      }
    }
  }

  Future<void> _finalizeAudioRecording({
    required bool showFailure,
    bool throwOnFailure = false,
    bool captureStopUnconfirmedIfActive = false,
  }) async {
    final state = _audioRecorder.state;
    final captureStopUnconfirmed =
        captureStopUnconfirmedIfActive ||
        _audioOnlyRecordingActive ||
        _audioOnlySources.isNotEmpty;
    final recorderNeedsFinalization =
        state.status == SubtitleAudioRecordingStatus.recording ||
        state.status == SubtitleAudioRecordingStatus.stopping ||
        (state.status == SubtitleAudioRecordingStatus.failed &&
            state.sessionId != null);
    final markCaptureStopUnconfirmed =
        captureStopUnconfirmed && recorderNeedsFinalization;
    if (state.status != SubtitleAudioRecordingStatus.recording &&
        state.status != SubtitleAudioRecordingStatus.stopping &&
        !(state.status == SubtitleAudioRecordingStatus.failed &&
            state.sessionId != null)) {
      if (showFailure && _retainSessionAudio && mounted) {
        setState(() => _retainSessionAudio = false);
      }
      return;
    }
    try {
      final sessionId =
          _diagnosticSessionId ?? state.sessionId ?? 'unavailable';
      final finalized = await _runSubtitleDiagnosticPhase(
        sessionId: sessionId,
        phase: 'audio_recording_finalize',
        operation: () => _audioRecorder.stop(
          failureReason: markCaptureStopUnconfirmed
              ? 'audio_capture_stop_unconfirmed'
              : null,
        ),
      );
      if (mounted) {
        setState(() {
          _audioRecordingState = finalized;
          _retainSessionAudio = false;
        });
      }
      throwIfExitCleanupFailed(
        failed: finalized.status == SubtitleAudioRecordingStatus.failed,
        message: finalized.error?.trim().isNotEmpty == true
            ? finalized.error!.trim()
            : '采集音频文件未能完成收尾。',
      );
    } on Object catch (error, stackTrace) {
      if (showFailure && mounted) {
        _showMessage(
          markCaptureStopUnconfirmed
              ? '音源停止未能确认；已写入的 WAV 按不完整录音保留在历史中，字幕记录不受影响。'
              : '采集音频未能完整保存；已保存的字幕不受影响。',
        );
      }
      if (throwOnFailure) Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> _openAudioRecordingsFolder() async {
    try {
      final directory = _audioRecorder.recordingsRootDirectory;
      await directory.create(recursive: true);
      final command = Platform.isWindows ? 'explorer.exe' : 'open';
      await Process.start(command, <String>[
        directory.path,
      ], mode: ProcessStartMode.detached);
    } on Object {
      if (mounted)
        _showMessage(
          '无法打开录音文件夹，请从应用数据目录访问：${_audioRecorder.recordingsRootPath}',
        );
    }
  }

  Future<void> _selectScreenRecordingTarget() async {
    if (_isPreparingForAppExit ||
        !Platform.isWindows ||
        _screenRecordingOperationInProgress) {
      return;
    }
    final operation = _beginTrackedOperation();
    setState(() => _screenRecordingOperationInProgress = true);
    try {
      await _screenRecorder.pickTarget();
      _startScreenStatePolling();
      await _pollScreenRecordingState();
    } on Object {
      if (mounted) _showMessage('无法打开 Windows 系统录屏选择器。');
    } finally {
      if (mounted) setState(() => _screenRecordingOperationInProgress = false);
      _finishTrackedOperation(operation);
    }
  }

  void _startScreenStatePolling() {
    if (_isPreparingForAppExit) return;
    _screenStatePollTimer?.cancel();
    _screenStatePollTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => unawaited(_pollScreenRecordingState()),
    );
  }

  Future<void> _pollScreenRecordingState() async {
    if (_isPreparingForAppExit ||
        _screenStatePollInProgress ||
        !Platform.isWindows) {
      return;
    }
    final operation = _beginTrackedOperation();
    _screenStatePollInProgress = true;
    try {
      final state = await _screenRecorder.getState();
      if (!mounted) return;
      setState(() => _screenRecordingState = state);
      if (state.status == 'pickerOpen' ||
          state.status == 'starting' ||
          state.status == 'recording' ||
          state.status == 'stopping') {
        _startScreenStatePolling();
        return;
      }

      _screenStatePollTimer?.cancel();
      _screenStatePollTimer = null;
      if (state.status == 'failed' && _screenRecordingSessionId != null) {
        _showMessage(state.message.isEmpty ? '屏幕录制失败。' : state.message);
        unawaited(_stopScreenRecording(updateUi: false));
      } else if (state.status == 'targetSelected') {
        _showMessage('已选择录屏目标：${state.targetName}');
      }
    } on Object {
      if (mounted) {
        _screenStatePollTimer?.cancel();
        _screenStatePollTimer = null;
        _showMessage('无法读取屏幕录制状态。');
      }
    } finally {
      _screenStatePollInProgress = false;
      _finishTrackedOperation(operation);
    }
  }

  AudioCaptureSourceState? _findActiveScreenAudioState({
    required String sessionId,
    required bool fromSubtitleSession,
  }) {
    final sources = _selectedCaptureSources;
    final states = fromSubtitleSession
        ? _sessionState?.sourceStates ?? const <AudioCaptureSourceState>[]
        : _audioOnlySourceStates.values.toList(growable: false);
    for (final source in sources) {
      final state = states.where(
        (item) =>
            item.sourceId == source.sourceId &&
            item.sourceKind == source.sourceKind &&
            item.sessionId == sessionId &&
            item.status == AudioCaptureSourceStatus.active,
      );
      if (state.isNotEmpty) return state.first;
    }
    return null;
  }

  Future<void> _startScreenRecording() async {
    if (_isPreparingForAppExit ||
        !Platform.isWindows ||
        _screenStopFuture != null ||
        _screenRecordingOperationInProgress ||
        !_screenRecordingState.hasTarget) {
      return;
    }
    final operation = _beginTrackedOperation();
    setState(() {
      _screenRecordingOperationInProgress = true;
      _operationInProgress = true;
      _operationLabel = '正在启动屏幕录制';
    });
    var retryingPreviousCleanup = false;

    final subtitleSessionId = _sessionIsActive
        ? _sessionState?.coordinator?.sessionId
        : null;
    final audioOnlySessionId = _audioOnlyRecordingActive
        ? _audioOnlySessionId
        : null;
    final sessionId = resolveScreenRecordingSessionId(
      fallbackSessionId: 'screen-recording-${widget.idFactory()}',
      activeSubtitleSessionId: subtitleSessionId,
      activeAudioOnlySessionId: audioOnlySessionId,
    );
    final captureAttemptId = 'screen-capture-${widget.idFactory()}';
    String? audioCaptureAttemptId;
    DesktopAudioCaptureSource? audioSource;
    var ownsAudioSource = false;
    var firstAudioFrameFailed = false;
    ScreenRecordingAudioStartupGate? firstAudioFrame;
    try {
      if (_hasUnconfirmedScreenRecordingCleanup) {
        retryingPreviousCleanup = true;
        await _stopScreenRecording(updateUi: false, throwOnFailure: true);
        if (_hasUnconfirmedScreenRecordingCleanup) {
          throw StateError('旧录屏音源仍未确认停止，已阻止开始新的录屏。');
        }
        retryingPreviousCleanup = false;
        if (!_screenRecordingState.hasTarget) {
          throw StateError('旧录屏已完成收尾，请重新选择录屏窗口后再开始。');
        }
      }
      setState(() {
        _screenRecordingStopRequested = false;
        _screenAudioWriteFailed = false;
        _screenAudioWriteFailureMessage = null;
        _screenAudioWriterReady = false;
        _screenAudioPreRoll.clear();
        _screenAudioWriteTail = Future<void>.value();
      });
      if (_screenRecordingWithAudio) {
        if (subtitleSessionId != null) {
          final audioState = _findActiveScreenAudioState(
            sessionId: subtitleSessionId,
            fromSubtitleSession: true,
          );
          if (audioState?.captureAttemptId == null) {
            throw StateError('当前同传没有已确认有效的音源，无法把音频写入视频。');
          }
          audioCaptureAttemptId = audioState!.captureAttemptId;
          audioSource = _selectedCaptureSources.firstWhere(
            (source) =>
                source.sourceId == audioState.sourceId &&
                source.sourceKind == audioState.sourceKind,
          );
        } else if (audioOnlySessionId != null) {
          final audioState = _findActiveScreenAudioState(
            sessionId: audioOnlySessionId,
            fromSubtitleSession: false,
          );
          if (audioState?.captureAttemptId == null) {
            throw StateError('独立录音尚未收到有效音源，暂时不能开始带声音的录屏。');
          }
          audioCaptureAttemptId = audioState!.captureAttemptId;
          audioSource = _selectedCaptureSources.firstWhere(
            (source) =>
                source.sourceId == audioState.sourceId &&
                source.sourceKind == audioState.sourceKind,
          );
        } else {
          audioSource = _selectedCaptureSources.firstOrNull;
          if (audioSource == null) {
            throw StateError('请先选择电脑播放声音或麦克风，或关闭视频内音轨选项。');
          }
          ownsAudioSource = true;
          audioCaptureAttemptId = captureAttemptId;
        }

        _screenRecordingSessionId = sessionId;
        _screenRecordingAudioSource = audioSource;
        _screenOwnsAudioSource = ownsAudioSource;

        final firstAudioFrameGate = ScreenRecordingAudioStartupGate();
        firstAudioFrame = firstAudioFrameGate;
        final audioSubscriptionGeneration = ++_screenAudioCaptureGeneration;
        final expectedSessionId = sessionId;
        final expectedCaptureAttemptId = audioCaptureAttemptId!;
        final expectedSourceId = audioSource.sourceId;
        final expectedSourceKind = audioSource.sourceKind;
        final audioFrameSubscription = widget.capture.frames.listen(
          (frame) {
            if (audioSubscriptionGeneration != _screenAudioCaptureGeneration) {
              return;
            }
            if (_screenAudioWriteFailed) return;
            if (!audioFrameMatchesCaptureIdentity(
              frame,
              sessionId: expectedSessionId,
              captureAttemptId: expectedCaptureAttemptId,
              sourceId: expectedSourceId,
              sourceKind: expectedSourceKind,
            )) {
              return;
            }
            final integrityFailure = screenRecordingAudioFrameFailure(frame);
            if (integrityFailure != null) {
              _screenAudioWriteFailed = true;
              _screenAudioWriteFailureMessage ??= integrityFailure;
              if (!firstAudioFrameGate.isCompleted) {
                firstAudioFrameFailed = true;
                firstAudioFrameGate.fail();
              }
              if (mounted) _showMessage(integrityFailure);
              _stopScreenRecordingAfterAudioFailure();
              return;
            }
            if (frame.sampleFormat !=
                AudioPcmSampleFormat.float32LittleEndian) {
              _screenAudioWriteFailed = true;
              _screenAudioWriteFailureMessage ??= '录屏音轨采样格式无效，未完成文件将保留。';
              if (!firstAudioFrameGate.isCompleted) {
                firstAudioFrameFailed = true;
                firstAudioFrameGate.fail();
              }
              _stopScreenRecordingAfterAudioFailure();
              return;
            }
            firstAudioFrameGate.addFrame(frame);
            if (!_screenAudioWriterReady) {
              if (!_screenAudioPreRoll.add(frame)) {
                _screenAudioWriteFailed = true;
                _screenAudioWriteFailureMessage ??= '录屏启动期间音频缓存过载，未完成文件将保留。';
              }
            } else {
              _queueScreenAudioFrame(frame);
            }
          },
          onError: (_) {
            if (audioSubscriptionGeneration != _screenAudioCaptureGeneration) {
              return;
            }
            if (_screenRecordingStopRequested) return;
            _screenAudioWriteFailed = true;
            _screenAudioWriteFailureMessage ??= '屏幕录制音轨中断，未完成文件将保留。';
            if (!firstAudioFrameGate.isCompleted) {
              firstAudioFrameFailed = true;
              firstAudioFrameGate.fail();
            }
            if (mounted) _showMessage('屏幕录制音轨中断。');
            _stopScreenRecordingAfterAudioFailure();
          },
          onDone: () {
            if (audioSubscriptionGeneration != _screenAudioCaptureGeneration) {
              return;
            }
            if (_screenRecordingStopRequested) return;
            _screenAudioWriteFailed = true;
            _screenAudioWriteFailureMessage ??= '屏幕录制音轨提前结束，未完成文件将保留。';
            if (!firstAudioFrameGate.isCompleted) {
              firstAudioFrameFailed = true;
              firstAudioFrameGate.fail();
            }
            if (mounted) _showMessage('屏幕录制音轨提前结束，正在保留未完成录屏。');
            _stopScreenRecordingAfterAudioFailure();
          },
        );
        _screenAudioFrameSubscription = audioFrameSubscription;
        _screenAudioFrameSubscriptionLease =
            ScreenRecordingAudioFrameSubscriptionLease(audioFrameSubscription);

        if (ownsAudioSource) {
          await widget.capture.startSource(
            source: audioSource,
            sessionId: sessionId,
            captureAttemptId: captureAttemptId,
          );
          _screenOwnsAudioSource = true;
        }
      }

      final firstFrame = firstAudioFrame == null
          ? null
          : await firstAudioFrame.firstFrame.timeout(
              const Duration(seconds: 12),
            );
      if (firstAudioFrameFailed) {
        throw StateError(_screenAudioWriteFailureMessage ?? '屏幕录制音轨在收到首帧前中断。');
      }
      final firstAudioQpcTime100ns = firstFrame?.qpcTime100ns;
      if (_screenAudioWriteFailed) {
        throw StateError(
          _screenAudioWriteFailureMessage ?? '等待屏幕录制时音频帧缓冲超过上限，请重试或改为无音轨录屏。',
        );
      }
      if (audioSource != null &&
          (firstAudioQpcTime100ns == null || firstAudioQpcTime100ns <= 0)) {
        throw StateError('音频源没有可靠的 Windows QPC 时间戳，无法同步写入视频。');
      }

      final recordingDirectory = Directory(_screenRecordingDirectoryPath);
      await recordingDirectory.create(recursive: true);
      _screenRecordingSessionId = sessionId;
      final started = await _screenRecorder.startRecording(
        recordingDirectory: recordingDirectory,
        sessionId: sessionId,
        retainAudio: audioSource != null,
        audioCaptureAttemptId: audioCaptureAttemptId,
        audioSourceId: audioSource?.sourceId,
        audioTimelineStartQpc100ns: firstAudioQpcTime100ns,
      );
      if (!started.isRecording) {
        throw StateError(started.message.isEmpty ? '录屏未能启动。' : started.message);
      }

      // Record native ownership immediately. Writing the audio pre-roll can
      // fail, but cleanup must still know that Media Foundation is recording.
      _screenRecordingState = started;
      _screenRecordingSessionId = sessionId;
      _screenRecordingAudioSource = audioSource;
      if (audioSource != null) {
        if (_screenAudioWriteFailed || _screenAudioPreRoll.hasOverflowed) {
          throw StateError(
            _screenAudioWriteFailureMessage ?? '录屏启动期间音频缓存超过上限，未完成文件将保留。',
          );
        }
        // Keep buffering until every pre-roll batch has been written. New
        // frames that arrive while native I/O is pending join the next batch;
        // switching to the live queue earlier could reorder or overlap writes.
        while (!_screenAudioPreRoll.isEmpty) {
          if (_screenAudioWriteFailed || _screenAudioPreRoll.hasOverflowed) {
            throw StateError(
              _screenAudioWriteFailureMessage ?? '录屏启动期间音频缓存超过上限，未完成文件将保留。',
            );
          }
          final bufferedFrames = _screenAudioPreRoll.takeBatch();
          await _enqueueScreenAudioWrite(
            bufferedFrames,
            failurePrefix: '录屏启动时写入音轨失败：',
            uiFailureMessage: '录屏启动时音轨写入失败，正在保留未完成录屏。',
            stopAfterFailure: false,
          );
          if (_screenAudioWriteFailed) {
            throw StateError(
              _screenAudioWriteFailureMessage ?? '录屏启动时写入音轨失败，未完成文件将保留。',
            );
          }
        }
        if (_screenAudioWriteFailed || _screenAudioPreRoll.hasOverflowed) {
          throw StateError(
            _screenAudioWriteFailureMessage ?? '录屏启动期间音频缓存超过上限，未完成文件将保留。',
          );
        }
      }
      _screenAudioWriterReady = audioSource != null;
      if (!mounted) return;
      setState(() {
        _operationLabel = null;
      });
      _startScreenStatePolling();
      _showMessage(
        audioSource == null
            ? '屏幕录制已开始（不含音轨）。'
            : '屏幕录制已开始；视频内音轨来自“${audioSource.displayName}”。',
      );
    } on Object catch (error) {
      Object? cleanupError;
      if (!retryingPreviousCleanup) {
        try {
          await _stopScreenRecording(updateUi: false);
        } on Object catch (stopError) {
          cleanupError = stopError;
        }
      }
      if (mounted) {
        setState(() {
          _screenRecordingOperationInProgress = false;
          _operationInProgress = false;
          _operationLabel = null;
        });
        _showMessage(
          cleanupError == null
              ? '屏幕录制未能启动：${_safeScreenError(error)}'
              : '屏幕录制未能启动，收尾也未确认：${_safeScreenError(cleanupError)}',
        );
      }
    } finally {
      try {
        if (mounted) {
          setState(() {
            _screenRecordingOperationInProgress = false;
            _operationInProgress = false;
            _operationLabel = null;
          });
        }
      } finally {
        _finishTrackedOperation(operation);
      }
    }
  }

  int _screenQueuedAudioFrames = 0;

  void _stopScreenRecordingAfterAudioFailure() {
    Timer.run(() {
      final status = _screenRecordingState.status;
      if (status == 'starting' ||
          status == 'recording' ||
          status == 'stopping' ||
          status == 'failed') {
        unawaited(_stopScreenRecording(updateUi: true));
      }
    });
  }

  void _queueScreenAudioFrame(AudioFrame frame) {
    if (_screenAudioWriteFailed) return;
    if (_screenQueuedAudioFrames >= 64) {
      _screenAudioWriteFailed = true;
      _screenAudioWriteFailureMessage ??= '录屏音轨队列过载，未完成文件将保留。';
      _stopScreenRecordingAfterAudioFailure();
      return;
    }
    _screenQueuedAudioFrames += 1;
    unawaited(
      _enqueueScreenAudioWrite(
        <AudioFrame>[frame],
        failurePrefix: '视频音轨写入失败：',
        uiFailureMessage: '视频音轨写入失败，正在保留未完成录屏。',
        onSettled: () => _screenQueuedAudioFrames -= 1,
      ),
    );
  }

  Future<void> _enqueueScreenAudioWrite(
    List<AudioFrame> frames, {
    required String failurePrefix,
    required String uiFailureMessage,
    bool stopAfterFailure = true,
    VoidCallback? onSettled,
  }) {
    final write = enqueueScreenRecordingAudioWrite(
      previous: _screenAudioWriteTail,
      write: () async {
        if (_screenAudioWriteFailed) return;
        await _screenRecorder.writeAudioFrames(frames);
      },
      onError: (Object error, StackTrace stackTrace) {
        _screenAudioWriteFailed = true;
        _screenAudioWriteFailureMessage ??= '$failurePrefix$error；未完成文件将保留。';
        if (mounted) _showMessage(uiFailureMessage);
        if (stopAfterFailure) _stopScreenRecordingAfterAudioFailure();
      },
    );
    _screenAudioWriteTail = write.whenComplete(() {
      onSettled?.call();
    });
    return _screenAudioWriteTail;
  }

  Future<void> _stopScreenRecording({
    required bool updateUi,
    bool throwOnFailure = false,
  }) {
    final existing = _screenStopFuture;
    if (existing != null) return existing;
    _screenRecordingStopRequested = true;
    final future = _finishScreenRecording(
      updateUi: updateUi,
      throwOnFailure: throwOnFailure,
    );
    _screenStopFuture = future.whenComplete(() {
      _screenStopFuture = null;
      _screenRecordingStopRequested = false;
      _resumeAfterCancelledExitWorkIfDrained();
      if (mounted) setState(() {});
    });
    if (mounted) setState(() {});
    return _screenStopFuture!;
  }

  Future<void> _finishScreenRecording({
    required bool updateUi,
    bool throwOnFailure = false,
  }) async {
    _screenStatePollTimer?.cancel();
    _screenStatePollTimer = null;
    Object? cleanupError;
    StackTrace? cleanupStackTrace;
    var sourceStopFailed = false;
    var recordingStopFailed = false;
    final ownsAudio = _screenOwnsAudioSource;
    final source = _screenRecordingAudioSource;
    if (ownsAudio && source != null) {
      try {
        await retryUnconfirmedScreenRecordingAudioStop(
          ownsAudioSource: ownsAudio,
          source: source,
          sessionId: _screenRecordingSessionId,
          stopSource: widget.capture.stopSource,
        );
      } on Object catch (error, stackTrace) {
        sourceStopFailed = true;
        cleanupError ??= error;
        cleanupStackTrace ??= stackTrace;
        if (updateUi && mounted) _showMessage('录屏音源停止状态未能确认。');
      }
    }
    final frameSubscriptionLease = _screenAudioFrameSubscriptionLease;
    if (frameSubscriptionLease != null) {
      try {
        await cancelScreenRecordingAudioFrameSubscription(
          lease: frameSubscriptionLease,
          onCancellationAttemptComplete: () {
            if (identical(
              _screenAudioFrameSubscriptionLease,
              frameSubscriptionLease,
            )) {
              _screenAudioFrameSubscription = null;
              _screenAudioFrameSubscriptionLease = null;
            }
          },
        );
      } on Object catch (error, stackTrace) {
        cleanupError ??= error;
        cleanupStackTrace ??= stackTrace;
        if (updateUi && mounted) _showMessage('录屏音频监听未能完成清理。');
      }
    }
    // Keep the live writer enabled until the source and subscription have
    // both stopped. Frames arriving during source shutdown must join the same
    // serialized tail instead of being stranded in the startup pre-roll.
    _screenAudioWriterReady = false;
    try {
      await _screenAudioWriteTail;
    } on Object catch (error, stackTrace) {
      cleanupError ??= error;
      cleanupStackTrace ??= stackTrace;
      if (updateUi && mounted) _showMessage('录屏音频写入队列未能正常完成。');
    }

    // Invalidate this listener even if cancel() failed. A stale subscription
    // must never write old-session frames into the next MP4 or startup buffer.
    _screenAudioCaptureGeneration++;

    final status = _screenRecordingState.status;
    if (status == 'pickerOpen' ||
        status == 'targetSelected' ||
        status == 'starting' ||
        status == 'recording' ||
        status == 'stopping' ||
        status == 'failed') {
      try {
        final stopped = await _screenRecorder.stopRecording(
          preservePartial: screenRecordingMustPreservePartial(
            audioWriteFailed: _screenAudioWriteFailed,
            sourceStopFailed: sourceStopFailed,
            audioCleanupFailed: cleanupError != null,
          ),
          failureMessage:
              _screenAudioWriteFailureMessage ??
              (sourceStopFailed
                  ? '录屏音源停止状态未能确认，文件保留为未完成录屏。'
                  : cleanupError != null
                  ? '录屏音频收尾状态未能确认，文件保留为未完成录屏。'
                  : null),
        );
        if (mounted) setState(() => _screenRecordingState = stopped);
        if (stopped.status == 'failed') {
          recordingStopFailed = true;
          try {
            throwIfExitCleanupFailed(
              failed: true,
              message: stopped.message.trim().isNotEmpty
                  ? stopped.message.trim()
                  : '屏幕录制文件收尾失败。',
            );
          } on Object catch (error, stackTrace) {
            cleanupError ??= error;
            cleanupStackTrace ??= stackTrace;
          }
        }
        if (updateUi && stopped.status == 'stopped') {
          _showMessage(
            stopped.path.isEmpty ? '屏幕录制已完成。' : '屏幕录制已保存：${stopped.path}',
          );
        } else if (updateUi && stopped.status == 'failed') {
          _showMessage(
            stopped.message.isEmpty ? '屏幕录制文件收尾失败。' : stopped.message,
          );
        }
      } on Object catch (error, stackTrace) {
        recordingStopFailed = true;
        cleanupError ??= error;
        cleanupStackTrace ??= stackTrace;
        if (updateUi && mounted) _showMessage('屏幕录制文件未能完成收尾。');
      }
    }
    _screenAudioPreRoll.clear();
    if (!recordingStopFailed && !sourceStopFailed) {
      _screenRecordingSessionId = null;
    }
    if (!sourceStopFailed) {
      _screenRecordingAudioSource = null;
      _screenOwnsAudioSource = false;
    }
    _screenQueuedAudioFrames = 0;
    if (mounted) {
      setState(() {
        _screenRecordingOperationInProgress = false;
        if (updateUi) _operationLabel = null;
      });
    }
    if (throwOnFailure && cleanupError != null) {
      Error.throwWithStackTrace(cleanupError, cleanupStackTrace!);
    }
  }

  Future<void> _stopScreenRecordingFromUi() async {
    if (_isPreparingForAppExit ||
        _screenRecordingOperationInProgress ||
        _operationInProgress) {
      return;
    }
    final operation = _beginTrackedOperation();
    setState(() {
      _screenRecordingOperationInProgress = true;
      _operationInProgress = true;
      _operationLabel = '正在停止并完成屏幕录制';
    });
    try {
      await _stopScreenRecording(updateUi: true);
    } finally {
      try {
        if (mounted) {
          setState(() {
            _screenRecordingOperationInProgress = false;
            _operationInProgress = false;
            _operationLabel = null;
          });
        }
      } finally {
        _finishTrackedOperation(operation);
      }
    }
  }

  Future<void> _openScreenRecordingsFolder() async {
    try {
      final directory = Directory(_screenRecordingDirectoryPath);
      await directory.create(recursive: true);
      await Process.start('explorer.exe', <String>[
        directory.path,
      ], mode: ProcessStartMode.detached);
    } on Object {
      if (mounted) _showMessage('无法打开录屏目录：$_screenRecordingDirectoryPath');
    }
  }

  String _safeScreenError(Object error) {
    final message = error.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
    return message.length > 180 ? '${message.substring(0, 180)}…' : message;
  }

  Future<void> _retrySave() async {
    final session = _session;
    if (session == null || _operationInProgress) return;
    final trackedOperation = _beginTrackedOperation();
    setState(() {
      _operationInProgress = true;
      _operationLabel = '正在重试保存字幕';
    });
    try {
      final result = await session.retrySave();
      if (mounted && result.status == SubtitleSessionSaveStatus.saved) {
        _showMessage('已保存到本机字幕历史。');
      }
    } on LiveSubtitleSessionException catch (error) {
      if (mounted) _showMessage(_friendlyError(error.code));
    } catch (_) {
      if (mounted) _showMessage(_friendlyError('storage_retry_failed'));
    } finally {
      if (mounted) {
        setState(() {
          _operationInProgress = false;
          _operationLabel = null;
          _sessionState = session.currentState;
        });
      }
      _finishTrackedOperation(trackedOperation);
    }
  }

  void _retryTranslation(SubtitleSegment segment) {
    final session = _session;
    if (session == null || !_sessionCanTranslateAgain) return;
    try {
      final result = session.retryTranslation(segment.key);
      if (!result.accepted &&
          result.status != SubtitleTranslationEnqueueStatus.duplicate) {
        _showMessage(
          result.status == SubtitleTranslationEnqueueStatus.queueFull
              ? '翻译队列已满，稍后可重试。'
              : '当前会话无法重试这条字幕。',
        );
      }
    } on LiveSubtitleSessionException catch (error) {
      _showMessage(_friendlyError(error.code));
    } catch (_) {
      _showMessage(_friendlyError('translation_retry_failed'));
    }
  }

  bool get _sessionCanTranslateAgain => switch (_sessionStatus) {
    SubtitleSessionStatus.preparing ||
    SubtitleSessionStatus.capturing ||
    SubtitleSessionStatus.paused => true,
    SubtitleSessionStatus.idle ||
    SubtitleSessionStatus.stopping ||
    SubtitleSessionStatus.stopped ||
    SubtitleSessionStatus.failed ||
    null => false,
  };

  Future<void> _toggleSubtitleWindow() async {
    if (!_canOpenSubtitleWindow ||
        _subtitleWindowBusy ||
        _historyNavigationInProgress) {
      return;
    }
    await _setSubtitleWindowVisible(!_subtitleWindowVisible);
  }

  Future<void> _openSubtitleHistory() async {
    if (!mounted || !_canOpenHistory) return;
    _historyNavigationInProgress = true;
    final operation = _beginTrackedOperation();
    _cancelSubtitleWindowUpdate();
    if (mounted) setState(() {});
    var operationFinished = false;
    try {
      await hideSubtitleWindowBeforeHistoryNavigation(
        subtitleWindow: _subtitleWindowHost,
        onHidden: () {
          if (mounted) setState(() => _subtitleWindowVisible = false);
        },
        onHideFailure: (_) {
          if (mounted) _showMessage('字幕窗未能确认隐藏；历史暂未打开，请重试或重新打开译学。');
        },
        openHistory: () async {
          if (!mounted) return;
          setState(() {
            _historyRouteVisible = true;
            // Remove the last texture ID from the widget tree before asking
            // Windows to unregister it. Merely covering the workbench route
            // leaves its native external texture alive on some compositor paths.
            _screenTarget = null;
          });
          await WidgetsBinding.instance.endOfFrame;
          if (widget.screenCapture != null) {
            try {
              await widget.screenCapture!.releasePreviewForNavigation();
              // Let the raster thread present a frame without the old external
              // texture before the history route gets its first frame.
              await WidgetsBinding.instance.endOfFrame;
            } on TimeoutException {
              if (mounted) {
                _showMessage(
                  '画面预览释放状态尚未确认；旧预览已清除，暂不打开历史。'
                  '释放完成后请重新选择画面。',
                );
              }
              return;
            } on Object {
              if (mounted) {
                _showMessage(
                  '画面预览释放失败；旧预览已清除，暂不打开历史。'
                  '请重试释放或重新打开译学。',
                );
              }
              return;
            }
          }
          if (mounted) {
            // Keep close cleanup blocked through frame removal and native
            // texture release, but not for the entire history modal lifetime.
            final openingHistory = widget.onOpenHistory();
            _finishTrackedOperation(operation);
            operationFinished = true;
            await openingHistory;
          }
        },
      );
    } finally {
      if (!operationFinished) _finishTrackedOperation(operation);
      _historyNavigationInProgress = false;
      if (mounted) {
        setState(() => _historyRouteVisible = false);
      }
    }
  }

  Future<void> _setSubtitleWindowVisible(bool visible) async {
    if (!mounted ||
        _subtitleWindowBusy ||
        (visible && _historyNavigationInProgress) ||
        (visible && (!_canOpenSubtitleWindow || _isPreparingForAppExit))) {
      return;
    }
    final operation = _beginTrackedOperation();
    setState(() {
      _subtitleWindowBusy = true;
      _subtitleWindowFailure = null;
    });
    try {
      if (visible) {
        await _subtitleWindowHost.show(_buildSubtitleWindowSnapshot());
      } else {
        await _subtitleWindowHost.hide();
      }
      if (mounted) setState(() => _subtitleWindowVisible = visible);
    } catch (error) {
      if (mounted) {
        final detail = error
            .toString()
            .replaceAll(RegExp(r'[\r\n]+'), ' ')
            .trim();
        final clipped = detail.length > 140
            ? '${detail.substring(0, 140)}…'
            : detail;
        final message = visible
            ? '字幕窗打开失败${clipped.isEmpty ? '' : '：$clipped'}；同传仍在继续。'
            : '字幕窗隐藏失败${clipped.isEmpty ? '' : '：$clipped'}；同传仍在继续。';
        setState(() => _subtitleWindowFailure = message);
        _showMessage(message);
      }
    } finally {
      if (mounted) setState(() => _subtitleWindowBusy = false);
      _finishTrackedOperation(operation);
    }
  }

  void _queueSubtitleWindowUpdate(LiveSubtitleSessionState state) {
    if (_isPreparingForAppExit || !_subtitleWindowVisible) return;
    _pendingSubtitleWindowState = state;
    if (_subtitleWindowUpdateTimer != null) return;
    _subtitleWindowUpdateTimer = Timer(_subtitleWindowUpdateInterval, () {
      _subtitleWindowUpdateTimer = null;
      final latestState = _pendingSubtitleWindowState;
      _pendingSubtitleWindowState = null;
      if (!mounted ||
          _isPreparingForAppExit ||
          !_subtitleWindowVisible ||
          latestState == null) {
        return;
      }
      _sendSubtitleWindowUpdate(latestState);
    });
  }

  void _queueSessionUiUpdate(
    LiveSubtitleSession session,
    LiveSubtitleSessionState state,
  ) {
    _pendingUiSession = session;
    _pendingUiSessionState = state;
    if (_sessionUiUpdateTimer != null) return;
    _sessionUiUpdateTimer = Timer(_sessionUiUpdateInterval, () {
      _sessionUiUpdateTimer = null;
      final latestSession = _pendingUiSession;
      final latestState = _pendingUiSessionState;
      _pendingUiSession = null;
      _pendingUiSessionState = null;
      if (!mounted ||
          _isPreparingForAppExit ||
          latestSession == null ||
          latestState == null ||
          !identical(_session, latestSession)) {
        return;
      }
      setState(() => _sessionState = latestState);
      _queueSubtitleWindowUpdate(latestState);
      final status = latestState.coordinator?.status;
      if ((status == SubtitleSessionStatus.failed ||
              status == SubtitleSessionStatus.stopped) &&
          (_audioRecorder.state.status ==
                  SubtitleAudioRecordingStatus.recording ||
              _audioRecorder.state.status ==
                  SubtitleAudioRecordingStatus.stopping ||
              (_audioRecorder.state.status ==
                      SubtitleAudioRecordingStatus.failed &&
                  !_audioRecorder.canStart))) {
        unawaited(
          _finalizeAudioRecording(
            showFailure: true,
            captureStopUnconfirmedIfActive: !latestSession.captureStopConfirmed,
          ),
        );
      }
    });
  }

  void _cancelPendingSessionUiUpdate() {
    _sessionUiUpdateTimer?.cancel();
    _sessionUiUpdateTimer = null;
    _pendingUiSession = null;
    _pendingUiSessionState = null;
  }

  void _cancelSubtitleWindowUpdate() {
    _subtitleWindowUpdateTimer?.cancel();
    _subtitleWindowUpdateTimer = null;
    _pendingSubtitleWindowState = null;
  }

  void _sendSubtitleWindowUpdate(LiveSubtitleSessionState state) {
    try {
      final update = _subtitleWindowHost.update(
        _buildSubtitleWindowSnapshot(state),
      );
      unawaited(
        update.then<void>(
          (_) => _subtitleWindowUpdateFailureReported = false,
          onError: (Object _, StackTrace __) {
            if (_subtitleWindowUpdateFailureReported) return;
            _subtitleWindowUpdateFailureReported = true;
            _reportSubtitleWindowFailure('字幕窗数据更新失败；同传识别仍在继续。');
          },
        ),
      );
    } catch (_) {
      if (_subtitleWindowUpdateFailureReported) return;
      _subtitleWindowUpdateFailureReported = true;
      _reportSubtitleWindowFailure('字幕窗数据更新失败；同传识别仍在继续。');
    }
  }

  void _reportSubtitleWindowFailure(String message) {
    if (!mounted) return;
    setState(() => _subtitleWindowFailure = message);
    _showMessage(message);
  }

  SubtitleWindowSnapshot _buildSubtitleWindowSnapshot([
    LiveSubtitleSessionState? sessionState,
  ]) {
    final state = sessionState ?? _sessionState;
    final coordinator = state?.coordinator;
    final queue = state?.translationQueue;
    final sources = _selectedCaptureSources;
    final source = sources.isEmpty ? null : sources.first;
    final status = coordinator?.status ?? SubtitleSessionStatus.idle;
    final recentSegments = <SubtitleSegment>[];
    for (final segment
        in (coordinator?.segments ?? const <SubtitleSegment>[]).reversed) {
      if (segment.transcript.text.trim().isEmpty) continue;
      recentSegments.add(segment);
      if (recentSegments.length == 8) break;
    }
    final cues = recentSegments.reversed.map((segment) {
      final translationStatus = segment.translationStatus;
      return SubtitleWindowCue(
        cueId:
            '${segment.transcript.captureAttemptId}:${segment.transcript.segmentId}',
        sourceText: segment.transcript.text,
        translatedText:
            translationStatus == SubtitleTranslationStatus.translated
            ? segment.translatedText
            : null,
        languageCode: segment.transcript.languageCode,
        sourceIsFinal: segment.transcript.isFinal,
        translationStatusLabel: switch (translationStatus) {
          SubtitleTranslationStatus.awaitingFinal => '识别中',
          SubtitleTranslationStatus.awaitingQueue => '等待翻译',
          SubtitleTranslationStatus.queued => '翻译排队中',
          SubtitleTranslationStatus.translating => '翻译中',
          SubtitleTranslationStatus.translated => '已翻译',
          SubtitleTranslationStatus.failed => '翻译失败',
          SubtitleTranslationStatus.cancelled => '翻译已取消',
          SubtitleTranslationStatus.skippedEmpty => '空字幕',
          SubtitleTranslationStatus.skippedDisabled => '翻译未开启',
          SubtitleTranslationStatus.skippedUnsupportedLanguage => '语种未识别，原文保留',
          SubtitleTranslationStatus.skippedSameLanguage => '原文就是目标语种',
        },
      );
    });
    final translationStatusLabel = !_translationEnabled
        ? '翻译未开启 · 原文照常保存'
        : queue?.activeRequestId != null
        ? '正在翻译'
        : (queue?.pendingCount ?? 0) > 0
        ? '待翻译 ${queue!.pendingCount} 条'
        : '翻译已开启';
    return SubtitleWindowSnapshot(
      sessionId: coordinator?.sessionId ?? 'no-session',
      sessionKind: _sessionKind,
      sessionStatus: status,
      sourceKind: source?.sourceKind ?? SubtitleAudioSourceKind.systemOutput,
      sourceLabel: sources.isEmpty
          ? '未选择音源'
          : sources
                .map(
                  (source) =>
                      '${_captureSourceKindLabel(source.sourceKind)} · ${source.displayName}',
                )
                .join(' + '),
      sourceStatusLabel: _selectedCaptureStatusLabel(state),
      sourceLanguageLabel: _subtitleSourceLanguageLabel,
      targetLanguageLabel: _languageLabel(_targetLanguageCode),
      translationStatusLabel: translationStatusLabel,
      displayPreferences: _displayPreferences,
      audioRecordingActive:
          _audioOnlyRecordingActive ||
          _audioRecordingState.status == SubtitleAudioRecordingStatus.recording,
      screenRecordingActive: _screenRecordingActive,
      screenRecordingHasTarget: _screenRecordingState.hasTarget,
      canChangeDirection:
          _sourceLanguageCode != 'auto' &&
          _targetLanguageCode != 'auto' &&
          _sourceLanguageCode != _targetLanguageCode &&
          !_screenRecordingActive &&
          !_screenRecordingOperationInProgress &&
          !_operationInProgress &&
          !_changingLanguages,
      cues: cues,
    );
  }

  Future<String> _handleSubtitleWindowControlAction(
    SubtitleWindowControlAction action,
  ) async {
    if (!mounted || _isPreparingForAppExit) return '译学正在退出，暂时无法操作。';

    final current = _displayPreferences;
    final updatedPreferences = switch (action) {
      SubtitleWindowControlAction.displayBilingual => current.copyWith(
        mode: SubtitleDisplayMode.bilingual,
      ),
      SubtitleWindowControlAction.displaySourceOnly => current.copyWith(
        mode: SubtitleDisplayMode.sourceOnly,
      ),
      SubtitleWindowControlAction.displayTranslatedOnly => current.copyWith(
        mode: SubtitleDisplayMode.translatedOnly,
      ),
      SubtitleWindowControlAction.fontCompact => current.copyWith(
        fontScale: SubtitleFontScale.compact,
      ),
      SubtitleWindowControlAction.fontStandard => current.copyWith(
        fontScale: SubtitleFontScale.standard,
      ),
      SubtitleWindowControlAction.fontLarge => current.copyWith(
        fontScale: SubtitleFontScale.large,
      ),
      SubtitleWindowControlAction.colorIce => current.copyWith(
        colorPreset: SubtitleColorPreset.ice,
      ),
      SubtitleWindowControlAction.colorAmber => current.copyWith(
        colorPreset: SubtitleColorPreset.amber,
      ),
      SubtitleWindowControlAction.colorMint => current.copyWith(
        colorPreset: SubtitleColorPreset.mint,
      ),
      SubtitleWindowControlAction.colorRose => current.copyWith(
        colorPreset: SubtitleColorPreset.rose,
      ),
      SubtitleWindowControlAction.toggleHighContrast => current.copyWith(
        highContrast: !current.highContrast,
      ),
      SubtitleWindowControlAction.opacityLight => current.copyWith(
        windowOpacity: 0.72,
      ),
      SubtitleWindowControlAction.opacityBalanced => current.copyWith(
        windowOpacity: 0.82,
      ),
      SubtitleWindowControlAction.opacityClear => current.copyWith(
        windowOpacity: 0.92,
      ),
      _ => null,
    };
    if (updatedPreferences != null) {
      _updateDisplayPreferences(updatedPreferences);
      final state = _sessionState;
      if (state != null) _queueSubtitleWindowUpdate(state);
      return '字幕显示设置已应用。';
    }

    switch (action) {
      case SubtitleWindowControlAction.switchDirection:
        return _reverseSubtitleSessionDirection();
      case SubtitleWindowControlAction.toggleAudioRecording:
        return _toggleSubtitleSessionAudioRecording();
      case SubtitleWindowControlAction.toggleScreenRecording:
        return _toggleSubtitleScreenRecording();
      default:
        return '不支持此字幕窗操作。';
    }
  }

  Future<String> _toggleSubtitleSessionAudioRecording() async {
    if (_operationInProgress ||
        _audioRecorder.state.status == SubtitleAudioRecordingStatus.stopping) {
      return '当前录音操作尚未完成，请稍后再试。';
    }

    if (_audioOnlyRecordingActive) {
      await _stopAudioOnlyRecording();
      final state = _sessionState;
      if (state != null) _queueSubtitleWindowUpdate(state);
      return '独立录音已停止并保存在本机。';
    }

    if (_audioRecordingState.status == SubtitleAudioRecordingStatus.recording) {
      await _finalizeAudioRecording(showFailure: true);
      final state = _sessionState;
      if (state != null) _queueSubtitleWindowUpdate(state);
      return _audioRecordingState.status == SubtitleAudioRecordingStatus.failed
          ? '录音未能完整收尾；已保存的字幕不受影响。'
          : '录音已完成并保存在本机。';
    }

    if (!_sessionIsActive) {
      if (!_canStartAudioOnly) {
        return '请先选择电脑声音或麦克风音源，再从主窗口启动独立录音。';
      }
      await _startAudioOnlyRecording();
      final state = _sessionState;
      if (state != null) _queueSubtitleWindowUpdate(state);
      return _audioOnlyRecordingActive ? '独立录音已开始。' : '独立录音未能启动，请检查主窗口状态。';
    }

    final sessionId = _sessionState?.coordinator?.sessionId;
    final captureAttemptId = _session?.captureAttemptId;
    final sources = _selectedCaptureSources;
    if (sessionId == null || sources.isEmpty) {
      return '当前字幕会话没有可保存的音源。';
    }

    final operation = _beginTrackedOperation();
    setState(() {
      _operationInProgress = true;
      _operationLabel = '正在开始保存本次同传音频';
      _retainSessionAudio = true;
    });
    try {
      await _audioRecorder.start(
        sessionId: sessionId,
        captureAttemptId: captureAttemptId,
        sources: sources
            .map(
              (source) => SubtitleSessionAudioSource(
                sourceId: source.sourceId,
                sourceKind: source.sourceKind,
                displayName: source.displayName,
              ),
            )
            .toList(growable: false),
        frames: widget.capture.frames,
      );
      if (mounted) setState(() => _audioRecordingState = _audioRecorder.state);
      return '本次同传音频开始保存到本机。';
    } catch (error) {
      if (mounted) setState(() => _retainSessionAudio = false);
      return '无法开始保存同传音频：${_safeScreenError(error)}';
    } finally {
      if (mounted) {
        setState(() {
          _operationInProgress = false;
          _operationLabel = null;
        });
        final state = _sessionState;
        if (state != null) _queueSubtitleWindowUpdate(state);
      }
      _finishTrackedOperation(operation);
    }
  }

  Future<String> _toggleSubtitleScreenRecording() async {
    if (_screenRecordingOperationInProgress || _operationInProgress) {
      return '录屏操作尚未完成，请稍后再试。';
    }
    if (_screenRecordingActive) {
      await _stopScreenRecordingFromUi();
    } else {
      if (!_screenRecordingState.hasTarget) {
        await _selectScreenRecordingTarget();
      }
      if (mounted && _screenRecordingState.hasTarget) {
        await _startScreenRecording();
      }
    }
    final state = _sessionState;
    if (state != null) _queueSubtitleWindowUpdate(state);
    return _screenRecordingActive
        ? '录屏已开始。'
        : _screenRecordingState.status == 'stopped'
        ? '录屏已停止并保存到本机。'
        : _screenRecordingState.message.isNotEmpty
        ? '录屏状态：${_screenRecordingState.message}'
        : '录屏未启动，请在主窗口检查录屏目标和音源。';
  }

  Future<String> _reverseSubtitleSessionDirection() async {
    if (_sourceLanguageCode == 'auto' || _targetLanguageCode == 'auto') {
      return '自动识别方向不能直接反转；请在主窗口选择明确的原文语言。';
    }
    if (_operationInProgress ||
        _changingLanguages ||
        _directionChangeInProgress ||
        _isPreparingForAppExit) {
      return '语言或会话设置正在变化，请稍后再试。';
    }
    if (_screenRecordingActive) {
      return '请先停止并保存当前录屏，再切换语言方向。';
    }
    if (_screenRecordingOperationInProgress) {
      return '录屏目标正在选择或录制准备中，请完成后再切换语言方向。';
    }

    _directionChangeInProgress = true;
    _changingLanguages = true;
    final trackedOperation = _beginTrackedOperation();
    if (mounted) setState(() {});
    try {
      return await _reverseSubtitleSessionDirectionTracked();
    } finally {
      _directionChangeInProgress = false;
      if (mounted) {
        setState(() => _changingLanguages = false);
      } else {
        _changingLanguages = false;
      }
      _finishTrackedOperation(trackedOperation);
    }
  }

  Future<String> _reverseSubtitleSessionDirectionTracked() async {
    final nextSource = _targetLanguageCode;
    final nextTarget = _sourceLanguageCode;
    LiveSubtitleTranslationSetup? nextSetup;
    if (_translationEnabled) {
      try {
        final resolvedSetup = await _resolveTranslationSetup(
          sourceLanguageCode: nextSource,
          targetLanguageCode: nextTarget,
        );
        if (!mounted || _isPreparingForAppExit) {
          return '译向切换已取消，正在关闭译学。';
        }
        nextSetup = resolvedSetup;
        if (resolvedSetup.routeKind ==
            SubtitleTranslationRouteKind.unavailable) {
          return '反向语言方向没有可用的 Provider；当前会话未停止。';
        }
        if (resolvedSetup.routeKind ==
            SubtitleTranslationRouteKind.remoteProfile) {
          return '反向 Provider 需要在主窗口确认；当前会话未停止。';
        }
      } catch (_) {
        return '无法确认反向语言的 Provider；当前会话未停止。';
      }
    }

    final modelInstalled = _usesMultilingualModel(nextSource)
        ? await widget.multilingualModelStore.isInstalled()
        : await widget.modelStore.isInstalled();
    if (!mounted || _isPreparingForAppExit) {
      return '译向切换已取消，正在关闭译学。';
    }
    if (!modelInstalled) {
      return '反向语音识别模型尚未安装；当前会话未停止，请先在主窗口下载模型。';
    }

    final wasActive = _sessionIsActive;
    final shouldRetainAudio =
        _audioRecordingState.status == SubtitleAudioRecordingStatus.recording;
    if (wasActive) await _stopSession();
    if (!mounted) return '当前页面已关闭。';
    if (_isPreparingForAppExit) return '译向切换已取消，正在关闭译学。';
    if (wasActive && _sessionIsActive) {
      return '旧会话未能确认停止；语言方向保持不变。';
    }

    setState(() {
      _sourceLanguageCode = nextSource;
      _targetLanguageCode = nextTarget;
      _translationSetup = nextSetup;
      _modelInstalled = true;
      _modelErrorCode = null;
      _retainSessionAudio = shouldRetainAudio;
      _changingLanguages = false;
    });

    if (!wasActive) {
      final state = _sessionState;
      if (state != null) _queueSubtitleWindowUpdate(state);
      return '语言方向已切换；新设置会用于下一次同传。';
    }

    if (_isPreparingForAppExit) return '译向切换已取消，正在关闭译学。';
    await _startSession();
    final state = _sessionState;
    if (state != null) _queueSubtitleWindowUpdate(state);
    return _sessionIsActive
        ? '已保存上一段字幕，并以反向语言开始新会话。'
        : '上一段字幕已保存，方向已切换；新会话未启动，请返回主窗口检查状态。';
  }

  Future<void> _enterCompactWindowMode() async {
    if (!_canEnterCompactWindowMode ||
        _compactWindowMode ||
        _windowTransitionInProgress ||
        _operationInProgress ||
        _isPreparingForAppExit) {
      return;
    }
    _windowTransitionInProgress = true;
    final transitionGeneration = ++_compactWindowTransitionGeneration;
    final operation = _beginTrackedOperation();
    setState(() {
      _operationInProgress = true;
      _operationLabel = '正在切换字幕置顶模式';
    });
    try {
      await enterCompactSubtitleWindow(
        actions: _compactWindowActions,
        normalMinimumSize: widget.workbenchMinimumWindowSize,
        compactMinimumSize: _compactMinimumSize,
        compactSize: _compactWindowSize,
        canContinue: () =>
            mounted &&
            transitionGeneration == _compactWindowTransitionGeneration &&
            !_isPreparingForAppExit,
        waitForLayout: () => WidgetsBinding.instance.endOfFrame,
        onRestoreStateChanged: (state) => _windowRestoreState = state,
        onCompactModeChanged: (compact) {
          if (!mounted) return;
          setState(() => _compactWindowMode = compact);
          widget.onCompactModeChanged?.call(compact);
        },
      );
    } catch (error) {
      var restored = true;
      if (error is CompactSubtitleWindowTransitionException &&
          !error.restored) {
        try {
          await _restoreWindowState(updateUi: false);
        } catch (_) {
          restored = false;
        }
      }
      if (mounted) {
        setState(() => _compactWindowMode = !restored);
        widget.onCompactModeChanged?.call(!restored);
      }
      _showMessage(
        restored ? '无法切换窗口状态；字幕会话仍在当前页面运行。' : '窗口状态未能全部恢复。请在紧凑字幕视图中再次点击退出以重试。',
      );
    } finally {
      _windowTransitionInProgress = false;
      if (mounted) {
        setState(() {
          _operationInProgress = false;
          _operationLabel = null;
        });
      }
      _finishTrackedOperation(operation);
    }
  }

  Future<void> _exitCompactWindowMode() async {
    if (!_compactWindowMode ||
        _windowTransitionInProgress ||
        _operationInProgress ||
        _isPreparingForAppExit) {
      return;
    }
    _windowTransitionInProgress = true;
    final operation = _beginTrackedOperation();
    setState(() {
      _operationInProgress = true;
      _operationLabel = '正在恢复主工作台窗口';
    });
    try {
      // Keep the lightweight subtitle tree mounted while the native window
      // grows. The full workbench must not lay out at the compact bounds.
      await _restoreWindowState(updateUi: false);
      if (mounted) {
        setState(() => _compactWindowMode = false);
        widget.onCompactModeChanged?.call(false);
      }
    } catch (_) {
      if (mounted) setState(() => _compactWindowMode = true);
      _showMessage('窗口状态恢复失败；请手动调整窗口后继续。');
    } finally {
      _windowTransitionInProgress = false;
      if (mounted) {
        setState(() {
          _operationInProgress = false;
          _operationLabel = null;
        });
      }
      _finishTrackedOperation(operation);
    }
  }

  Future<void> _restoreWindowState({required bool updateUi}) async {
    final restore = _windowRestoreState;
    if (restore == null || !_isDesktop) return;
    await _cancelCompactResizesAndWait();
    await restoreCompactSubtitleWindow(
      actions: _compactWindowActions,
      state: restore,
    );
    _windowRestoreState = null;
    if (updateUi && mounted) {
      setState(() => _compactWindowMode = false);
    }
  }

  Future<void> _beginWindowDrag() async {
    if (!_isDesktop) return;
    try {
      await _compactWindowActions.startDragging();
    } catch (_) {
      // The compact controls remain usable if native dragging is unavailable.
    }
  }

  void _beginWindowResize(DragStartDetails details) {
    if (!_isDesktop || !_compactWindowMode || _operationInProgress) return;
    _resizeStartPointer = details.globalPosition;
    unawaited(_loadWindowBoundsForResize());
  }

  Future<void> _loadWindowBoundsForResize() async {
    final generation = _compactResizeGeneration;
    try {
      final bounds = await _compactWindowActions.getBounds();
      if (generation != _compactResizeGeneration ||
          _isPreparingForAppExit ||
          !_compactWindowMode) {
        return;
      }
      _resizeStartBounds = bounds;
    } catch (_) {
      _resizeStartBounds = null;
    }
  }

  void _updateWindowResize(DragUpdateDetails details) {
    final bounds = _resizeStartBounds;
    final origin = _resizeStartPointer;
    if (!_isDesktop ||
        !_compactWindowMode ||
        _isPreparingForAppExit ||
        _operationInProgress ||
        bounds == null ||
        origin == null) {
      return;
    }
    final width = (bounds.width + details.globalPosition.dx - origin.dx)
        .clamp(_compactMinimumSize.width, 1600.0)
        .toDouble();
    final height = (bounds.height + details.globalPosition.dy - origin.dy)
        .clamp(_compactMinimumSize.height, 1000.0)
        .toDouble();
    _queuedCompactWindowSize = Size(width, height);
    _compactResizeTimer?.cancel();
    _compactResizeTimer = Timer(const Duration(milliseconds: 16), () {
      _compactResizeTimer = null;
      _startCompactResizePump();
    });
  }

  void _startCompactResizePump() {
    if (_compactResizeFuture != null ||
        _queuedCompactWindowSize == null ||
        !_compactWindowMode ||
        _isPreparingForAppExit) {
      return;
    }
    final generation = _compactResizeGeneration;
    final future = _applyQueuedCompactResizes(generation);
    _compactResizeFuture = future;
    unawaited(
      future.whenComplete(() {
        if (identical(_compactResizeFuture, future)) {
          _compactResizeFuture = null;
        }
        _resumeAfterCancelledExitWorkIfDrained();
        if (generation == _compactResizeGeneration &&
            _queuedCompactWindowSize != null &&
            _compactWindowMode &&
            !_isPreparingForAppExit) {
          _startCompactResizePump();
        }
      }),
    );
  }

  Future<void> _applyQueuedCompactResizes(int generation) async {
    while (mounted &&
        generation == _compactResizeGeneration &&
        _compactWindowMode &&
        !_isPreparingForAppExit) {
      final size = _queuedCompactWindowSize;
      if (size == null) return;
      _queuedCompactWindowSize = null;
      try {
        final applied = await applyCompactSubtitleResizeIfCurrent(
          generation: generation,
          currentGeneration: _compactResizeGeneration,
          canResize: mounted && _compactWindowMode && !_isPreparingForAppExit,
          size: size,
          apply: _compactWindowActions.setSize,
        );
        if (!applied) return;
      } catch (_) {
        _queuedCompactWindowSize = null;
        if (mounted) _showMessage('无法调整紧凑字幕窗大小，请退出后重新进入该模式。');
        return;
      }
    }
  }

  Future<void> _cancelCompactResizesAndWait({
    AppExitCleanupCancellation? cancellation,
  }) async {
    _compactResizeGeneration++;
    _compactResizeTimer?.cancel();
    _compactResizeTimer = null;
    _queuedCompactWindowSize = null;
    final inFlight = _compactResizeFuture;
    if (inFlight != null) {
      await _awaitExitWorkOrCancellation(inFlight, cancellation);
    }
  }

  void _finishWindowResize() {
    _compactResizeTimer?.cancel();
    _compactResizeTimer = null;
    if (!_isPreparingForAppExit && _queuedCompactWindowSize != null) {
      _startCompactResizePump();
    }
    _resizeStartBounds = null;
    _resizeStartPointer = null;
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _showMultilingualModelNotice() async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('多语言识别模型来源与许可'),
        content: const SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Whisper Tiny multilingual INT8 与 Silero VAD 只在你点击下载后保存到本机；应用预览包不捆绑这组权重。模型文件按固定版本下载并逐项校验。',
              ),
              SizedBox(height: 12),
              Text('模型来源与上游许可声明：'),
              SelectableText(
                'Whisper Tiny 转换模型：\n'
                'https://huggingface.co/csukuangfj/sherpa-onnx-whisper-tiny/tree/18e7b4cce9526312a66981ec3af7b9446b70db66\n\n'
                'Silero VAD：\n'
                'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx\n\n'
                'Whisper 上游 MIT 声明：\n'
                'https://github.com/openai/whisper#license\n\n'
                'Silero VAD 上游 MIT 声明：\n'
                'https://github.com/snakers4/silero-vad#license',
              ),
              SizedBox(height: 12),
              Text(
                '限制：转换权重仓库未提供独立 model card 或 license 元数据，上游许可说明不构成对转换文件权利链的独立法律确认。正式再分发权重前仍需确认转换模型许可。录音和字幕不会因安装模型自动上传。',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_isDesktop) return _buildUnsupportedPlatform(context);
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (_compactWindowMode) return _buildCompactSubtitleView(context);
            final isWide = constraints.maxWidth >= 1080;
            return SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                isWide ? 24 : 20,
                isWide ? 20 : 12,
                isWide ? 24 : 20,
                isWide ? 28 : 12,
              ),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1480),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildPageHeader(context),
                      const SizedBox(height: 16),
                      if (widget.screenCapture != null && isWide)
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  _buildScreenPreviewPanel(context),
                                  const SizedBox(height: 14),
                                  _buildTranscriptPanel(context),
                                ],
                              ),
                            ),
                            const SizedBox(width: 18),
                            SizedBox(
                              width: 340,
                              child: _buildWorkbenchSidebar(context),
                            ),
                          ],
                        )
                      else if (widget.screenCapture != null) ...[
                        _buildScreenPreviewPanel(context),
                        const SizedBox(height: 14),
                        _buildNarrowSessionActions(context),
                        const SizedBox(height: 14),
                        _buildTranscriptPanel(context),
                        const SizedBox(height: 14),
                        _buildWorkbenchDetails(
                          context,
                          includeSessionOptions: true,
                        ),
                        const SizedBox(height: 14),
                        _buildRecentHistoryPanel(context),
                      ] else if (isWide) ...[
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 348,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  _buildNarrowSessionActions(context),
                                  const SizedBox(height: 12),
                                  _buildWorkbenchDetails(context),
                                  const SizedBox(height: 12),
                                  _buildRecentHistoryPanel(context),
                                ],
                              ),
                            ),
                            const SizedBox(width: 18),
                            Expanded(child: _buildTranscriptPanel(context)),
                          ],
                        ),
                      ] else ...[
                        _buildNarrowSessionActions(context),
                        const SizedBox(height: 16),
                        _buildTranscriptPanel(context),
                        const SizedBox(height: 14),
                        _buildWorkbenchDetails(context),
                        const SizedBox(height: 14),
                        _buildRecentHistoryPanel(context),
                      ],
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildUnsupportedPlatform(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.desktop_access_disabled,
                    size: 40,
                    color: colors.error,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'AI 同传仅支持桌面端',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  const Text('当前桌面工作台支持 Windows 与 macOS 系统播放音源。'),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPageHeader(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'AI 同传',
                style: textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '桌面音频 · 实时原文与译文 · 本机字幕历史',
                style: textTheme.bodyLarge?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        OutlinedButton.icon(
          onPressed: _canOpenHistory ? _openSubtitleHistory : null,
          icon: const Icon(Icons.history_rounded),
          label: const Text('字幕历史'),
        ),
      ],
    );
  }

  Widget _buildScreenPreviewPanel(BuildContext context) {
    if (widget.screenCapture == null) {
      if (Platform.isWindows) {
        return _buildScreenRecordingTargetPanel(context, interactive: true);
      }
      return _buildAudioOnlyCapturePrompt(context);
    }
    final colors = Theme.of(context).colorScheme;
    final target = _screenTarget;
    if (target == null) {
      return _buildUnselectedScreenPrompt(context);
    }
    final aspectRatio = target.height == 0
        ? 16 / 9
        : (target.width / target.height).clamp(1.25, 2.2).toDouble();
    return _SurfaceCard(
      title: '桌面画面',
      icon: Icons.desktop_windows_rounded,
      trailing: _StatusBadge(
        label: '${target.width} × ${target.height}',
        icon: Icons.aspect_ratio_rounded,
        tone: colors.primary,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              // Preserve the selected screen's aspect ratio while capping its
              // height, so the preview stays useful without pushing session
              // controls and subtitles below the fold.
              final naturalHeight = constraints.maxWidth / aspectRatio;
              final maxPreviewHeight = _sessionIsActive ? 260.0 : 360.0;
              final previewHeight = naturalHeight > maxPreviewHeight
                  ? maxPreviewHeight
                  : naturalHeight;
              final previewWidth = previewHeight * aspectRatio;
              return SizedBox(
                height: previewHeight,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: ColoredBox(
                    color: const Color(0xff111820),
                    child: Center(
                      child: SizedBox(
                        width: previewWidth,
                        height: previewHeight,
                        child: _historyRouteVisible
                            ? const SizedBox.expand()
                            : Texture(
                                textureId: target.textureId,
                                filterQuality: FilterQuality.medium,
                              ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              const Icon(
                Icons.radio_button_checked_rounded,
                color: Color(0xff19b889),
                size: 16,
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  '正在捕获：${target.targetName}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildScreenRecordingTargetPanel(
    BuildContext context, {
    required bool interactive,
  }) {
    final state = _screenRecordingState;
    final hasTarget = state.hasTarget || state.isRecording;
    final colors = Theme.of(context).colorScheme;
    final pickerBusy = state.status == 'pickerOpen';
    final recording = _screenRecordingActive;
    return _SurfaceCard(
      title: '录屏目标',
      icon: Icons.desktop_windows_rounded,
      trailing: recording
          ? const _StatusBadge(
              label: '录制中',
              icon: Icons.fiber_manual_record_rounded,
              tone: Color(0xffd33d45),
            )
          : hasTarget
          ? const _StatusBadge(
              label: '已选择',
              icon: Icons.check_circle_outline_rounded,
              tone: Color(0xff19866a),
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                recording ? Icons.fiber_manual_record_rounded : Icons.crop_free,
                color: recording ? colors.error : colors.onSurfaceVariant,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      recording
                          ? '正在录制 ${state.targetName}'
                          : hasTarget
                          ? state.targetName
                          : '尚未选择窗口或屏幕',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    Text(
                      recording
                          ? '${state.framesWritten} 帧 · ${(state.durationUs / 1000000).toStringAsFixed(1)} 秒'
                          : '只在开始录屏时采集画面；不选画面也可以开始音频同传。',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: colors.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              if (interactive) ...[
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  key: const ValueKey('screen-recording-select-target'),
                  onPressed:
                      recording ||
                          pickerBusy ||
                          _screenRecordingOperationInProgress ||
                          _operationInProgress
                      ? null
                      : _selectScreenRecordingTarget,
                  icon: Icon(
                    pickerBusy
                        ? Icons.hourglass_top_rounded
                        : Icons.screenshot_monitor_rounded,
                  ),
                  label: Text(
                    pickerBusy
                        ? '等待选择…'
                        : hasTarget
                        ? '更换目标'
                        : '选择窗口或屏幕',
                  ),
                ),
              ],
            ],
          ),
          if (state.status == 'failed' && state.message.isNotEmpty) ...[
            const SizedBox(height: 8),
            _InlineNotice(
              icon: Icons.error_outline_rounded,
              message: state.message,
              isError: true,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildAudioOnlyCapturePrompt(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: colors.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(Icons.graphic_eq_rounded, color: colors.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('音频同传', style: Theme.of(context).textTheme.titleSmall),
                  Text(
                    '只听声音也能开始同传。',
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: colors.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildUnselectedScreenPrompt(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final unsupported = _screenCaptureSupported == false;
    final failed = _screenCaptureError != null;
    return Material(
      color: colors.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: colors.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(Icons.desktop_windows_outlined, color: colors.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    unsupported
                        ? '当前系统不能采集画面'
                        : failed
                        ? '画面采集暂不可用'
                        : '未选择画面',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  Text(
                    failed
                        ? _screenCaptureError!
                        : unsupported
                        ? '仍可开始音频同传；录屏不可用。'
                        : '需要录屏时，请打开“同传设置”→“录制与音源”并选择窗口或屏幕。',
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: colors.onSurfaceVariant),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWorkbenchSidebar(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SurfaceCard(
          title: '字幕会话',
          icon: Icons.graphic_eq_rounded,
          child: _buildSessionActions(context),
        ),
        const SizedBox(height: 12),
        _buildWorkbenchDetails(context, includeSessionOptions: true),
        const SizedBox(height: 12),
        _buildRecentHistoryPanel(context),
      ],
    );
  }

  Widget _buildNarrowSessionActions(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (Platform.isWindows && widget.screenCapture == null) ...[
          _buildScreenRecordingTargetPanel(context, interactive: true),
          const SizedBox(height: 12),
        ],
        _SurfaceCard(
          title: '字幕会话',
          icon: Icons.graphic_eq_rounded,
          child: _buildSessionActions(context, primaryOnly: true),
        ),
      ],
    );
  }

  Widget _buildWorkbenchDetails(
    BuildContext context, {
    bool includeSessionOptions = false,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          color: Theme.of(context).colorScheme.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: ExpansionTile(
            key: const ValueKey('subtitle-unified-settings'),
            controller: _unifiedSettingsController,
            leading: const Icon(Icons.tune_rounded),
            title: const Text('同传设置'),
            subtitle: Text(
              '${_languageName(_sourceLanguageCode)} → ${_languageName(_targetLanguageCode)}',
            ),
            childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildSettingsCategory(
                    context,
                    key: const ValueKey('subtitle-language-settings'),
                    title: '语言与识别',
                    subtitle:
                        '${_languageName(_sourceLanguageCode)} → ${_languageName(_targetLanguageCode)} · 识别模型与翻译服务',
                    icon: Icons.translate_rounded,
                    controller: _languageSettingsController,
                    onExpansionChanged: (expanded) =>
                        _handleSettingsCategoryExpansion(
                          'subtitle-language-settings',
                          expanded,
                        ),
                    child: _buildControls(
                      context,
                      includeSessionActions: false,
                      includeAudioSourceControls: false,
                    ),
                  ),
                  const SizedBox(height: 8),
                  _buildSettingsCategory(
                    context,
                    key: const ValueKey('subtitle-recording-settings'),
                    title: '录制与音源',
                    subtitle: _recordingSettingsSummary,
                    icon: Icons.radio_button_checked_rounded,
                    controller: _recordingSettingsController,
                    onExpansionChanged: (expanded) =>
                        _handleSettingsCategoryExpansion(
                          'subtitle-recording-settings',
                          expanded,
                        ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _buildAudioSourceControls(context),
                        const SizedBox(height: 10),
                        if (widget.screenCapture != null) ...[
                          _buildScreenCaptureControls(context),
                          const SizedBox(height: 10),
                        ],
                        _buildSessionActions(context, secondaryOnly: true),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  _buildSettingsCategory(
                    context,
                    key: const ValueKey('subtitle-window-settings'),
                    title: '字幕窗外观',
                    subtitle:
                        '${_displayPreferences.mode.label} · ${_displayPreferences.fontScale.label} · 点击字幕窗调整',
                    icon: Icons.closed_caption_rounded,
                    controller: _appearanceSettingsController,
                    onExpansionChanged: (expanded) =>
                        _handleSettingsCategoryExpansion(
                          'subtitle-window-settings',
                          expanded,
                        ),
                    child: _buildSubtitleAppearanceControls(context),
                  ),
                  const SizedBox(height: 8),
                  _buildSettingsCategory(
                    context,
                    key: const ValueKey('subtitle-privacy-settings'),
                    title: '采集与隐私',
                    subtitle: '查看音频来源、画面采集与本机保存说明',
                    icon: Icons.shield_outlined,
                    controller: _privacySettingsController,
                    onExpansionChanged: (expanded) =>
                        _handleSettingsCategoryExpansion(
                          'subtitle-privacy-settings',
                          expanded,
                        ),
                    child: _buildReadinessBanner(context),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  String get _recordingSettingsSummary {
    if (_screenRecording) return '录屏进行中';
    if (_audioOnlyRecordingActive) return '独立录音进行中';
    if (_retainSessionAudio) return '已开启本机录音保存';
    final enabledSources = <String>[
      if (_systemAudioEnabled) '电脑播放声',
      if (_microphoneCaptureEnabled) '麦克风',
    ];
    final sourceSummary = enabledSources.isEmpty
        ? '未启用音源'
        : enabledSources.join(' + ');
    return '$sourceSummary · 音频与屏幕录制';
  }

  Widget _buildSettingsCategory(
    BuildContext context, {
    required Key key,
    required String title,
    required String subtitle,
    required IconData icon,
    required Widget child,
    ExpansibleController? controller,
    ValueChanged<bool>? onExpansionChanged,
  }) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        key: key,
        controller: controller,
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
        onExpansionChanged: onExpansionChanged,
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        children: [child],
      ),
    );
  }

  void _handleSettingsCategoryExpansion(String expandedKey, bool expanded) {
    if (!expanded) return;
    if (expandedKey != 'subtitle-language-settings') {
      _languageSettingsController.collapse();
    }
    if (expandedKey != 'subtitle-recording-settings') {
      _recordingSettingsController.collapse();
    }
    if (expandedKey != 'subtitle-window-settings') {
      _appearanceSettingsController.collapse();
    }
    if (expandedKey != 'subtitle-privacy-settings') {
      _privacySettingsController.collapse();
    }
  }

  Widget _buildSubtitleAppearanceControls(BuildContext context) {
    final preferences = _displayPreferences;
    void apply(SubtitleDisplayPreferences updated) {
      _updateDisplayPreferences(updated);
      final state = _sessionState;
      if (state != null) _queueSubtitleWindowUpdate(state);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('字幕外观', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 10),
        DropdownButtonFormField<SubtitleDisplayMode>(
          key: ValueKey('subtitle-mode-${preferences.mode.name}'),
          initialValue: preferences.mode,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: '显示内容',
            border: OutlineInputBorder(),
          ),
          items: [
            for (final mode in SubtitleDisplayMode.values)
              DropdownMenuItem(value: mode, child: Text(mode.label)),
          ],
          onChanged: (mode) {
            if (mode != null) apply(preferences.copyWith(mode: mode));
          },
        ),
        const SizedBox(height: 10),
        DropdownButtonFormField<SubtitleFontScale>(
          key: ValueKey('subtitle-font-${preferences.fontScale.name}'),
          initialValue: preferences.fontScale,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: '字幕字号',
            border: OutlineInputBorder(),
          ),
          items: [
            for (final scale in SubtitleFontScale.values)
              DropdownMenuItem(value: scale, child: Text(scale.label)),
          ],
          onChanged: (scale) {
            if (scale != null) apply(preferences.copyWith(fontScale: scale));
          },
        ),
        const SizedBox(height: 10),
        DropdownButtonFormField<SubtitleColorPreset>(
          key: ValueKey('subtitle-color-${preferences.colorPreset.name}'),
          initialValue: preferences.colorPreset,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: '字幕颜色',
            border: OutlineInputBorder(),
          ),
          items: [
            for (final preset in SubtitleColorPreset.values)
              DropdownMenuItem(value: preset, child: Text(preset.label)),
          ],
          onChanged: (preset) {
            if (preset != null)
              apply(preferences.copyWith(colorPreset: preset));
          },
        ),
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: const Text('高对比字幕背景'),
          value: preferences.highContrast,
          onChanged: (enabled) =>
              apply(preferences.copyWith(highContrast: enabled)),
        ),
        Text('字幕窗透明度 · ${(preferences.windowOpacity * 100).round()}%'),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (opacity, label) in const <(double, String)>[
              (0.72, '更透明'),
              (0.82, '均衡'),
              (0.92, '更清晰'),
            ])
              ChoiceChip(
                label: Text(label),
                selected: (preferences.windowOpacity - opacity).abs() < 0.01,
                onSelected: (_) =>
                    apply(preferences.copyWith(windowOpacity: opacity)),
              ),
          ],
        ),
      ],
    );
  }

  String _languageName(String code) =>
      AsrLanguageRegistry.displayLabel(code) ?? code;

  Widget _buildScreenCaptureControls(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final hasTarget = _screenTarget != null;
    final initializationFailed =
        _screenCaptureSupported == null && _screenCaptureError != null;
    return _SurfaceCard(
      title: '画面与录制',
      icon: Icons.videocam_outlined,
      trailing: _screenRecording
          ? const _StatusBadge(
              label: '录制中',
              icon: Icons.fiber_manual_record_rounded,
              tone: Color(0xffd33d45),
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!hasTarget)
            FilledButton.tonalIcon(
              key: initializationFailed
                  ? const ValueKey('screen-capture-retry-controls')
                  : const ValueKey('screen-capture-select-controls'),
              onPressed:
                  _screenCaptureBusy ||
                      _screenCaptureChecking ||
                      _screenCaptureSupported == false
                  ? null
                  : initializationFailed
                  ? _checkScreenCaptureSupport
                  : _selectDesktopCaptureTarget,
              icon: Icon(
                initializationFailed
                    ? Icons.refresh_rounded
                    : Icons.screenshot_monitor_rounded,
              ),
              label: Text(
                _screenCaptureChecking
                    ? '正在重新检测采集'
                    : initializationFailed
                    ? '重新检测采集'
                    : '选择窗口或屏幕',
              ),
            )
          else ...[
            if (!_screenRecording)
              FilledButton.icon(
                onPressed: _screenCaptureBusy ? null : _startDesktopRecording,
                icon: const Icon(Icons.fiber_manual_record_rounded),
                label: const Text('开始录屏（含系统声音）'),
              )
            else
              FilledButton.tonalIcon(
                onPressed: _screenCaptureBusy ? null : _stopDesktopRecording,
                icon: const Icon(Icons.stop_rounded),
                label: const Text('停止并保存 MP4'),
              ),
            if (!_screenRecording) ...[
              const SizedBox(height: 7),
              OutlinedButton.icon(
                key: const ValueKey('screen-capture-change-target'),
                onPressed: _screenCaptureBusy
                    ? null
                    : _selectDesktopCaptureTarget,
                icon: const Icon(Icons.desktop_windows_outlined),
                label: const Text('更换录制窗口或屏幕'),
              ),
            ],
            const SizedBox(height: 7),
            OutlinedButton.icon(
              onPressed: _screenCaptureBusy ? null : _stopDesktopScreenCapture,
              icon: const Icon(Icons.videocam_off_outlined),
              label: const Text('停止画面采集'),
            ),
          ],
          if (_screenCaptureBusy) ...[
            const SizedBox(height: 10),
            const LinearProgressIndicator(),
          ],
          if (_screenCaptureError case final error?) ...[
            const SizedBox(height: 8),
            _InlineNotice(
              icon: Icons.error_outline_rounded,
              message: error,
              isError: true,
            ),
          ],
          if (_recordingPath case final path?) ...[
            const SizedBox(height: 8),
            Text(
              '保存位置：$path',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          if (_lastRecordingPath case final path?) ...[
            const SizedBox(height: 8),
            Text(
              '最近录屏：$path',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: 7),
          Text(
            '录屏由你单独开启，文件保存在本机；声音来自系统播放混音，不含麦克风。',
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: colors.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _buildRecentHistoryPanel(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return _SurfaceCard(
      title: '最近字幕历史',
      icon: Icons.history_rounded,
      trailing: TextButton(
        onPressed: _canOpenHistory ? _openSubtitleHistory : null,
        child: const Text('全部'),
      ),
      child: _recentSessions.isEmpty
          ? Text(
              '确认后的字幕会保存在这里。',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: colors.onSurfaceVariant),
            )
          : Column(
              children: [
                for (final session in _recentSessions.take(3))
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    leading: Icon(switch (session.kind) {
                      SubtitleSessionKind.video => Icons.movie_outlined,
                      SubtitleSessionKind.meeting => Icons.groups_2_outlined,
                      SubtitleSessionKind.livestream => Icons.live_tv_outlined,
                    }),
                    title: Text(
                      '${_sessionKindName(session.kind)} · ${session.segments.length} 条字幕',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      session.startedAtUtc.toLocal().toString().substring(
                        0,
                        16,
                      ),
                    ),
                    onTap: _canOpenHistory ? _openSubtitleHistory : null,
                  ),
              ],
            ),
    );
  }

  String _sessionKindName(SubtitleSessionKind kind) => switch (kind) {
    SubtitleSessionKind.video => '视频',
    SubtitleSessionKind.meeting => '会议',
    SubtitleSessionKind.livestream => '直播',
  };

  Widget _buildReadinessBanner(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final sourceMessage = Platform.isWindows
        ? '字幕识别使用默认播放设备的共享模式混音；画面预览只在你选择窗口或显示器后开始，录屏也必须单独开启。'
        : 'macOS 将采集所选显示器关联的音频，需要系统屏幕录制授权；本页只接收音频，不处理画面。';
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.primaryContainer.withValues(alpha: .34),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline_rounded, color: colors.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '先确认当前系统音源范围',
                  style: Theme.of(context).textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(
                  sourceMessage,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  Platform.isWindows
                      ? '系统声音与麦克风会分别显示状态并进入同一字幕时间轴；画面和音频文件都只在你单独开启录制后保存在本机。'
                      : '会议场景只显示系统音源中捕获到的声音；会话默认只保存确认后的字幕文字。',
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: colors.onSurfaceVariant),
                ),
                const SizedBox(height: 6),
                Text(
                  '当前为 Windows 实现验证版：英中流式识别已接线，但准确率、延迟和资源占用尚未完成固定语料与 Windows 目标设备验收。macOS 将在 Windows 阶段完成后推进。',
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: colors.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildControls(
    BuildContext context, {
    bool includeSessionActions = true,
    bool includeAudioSourceControls = true,
    bool includeNavigationKeys = true,
  }) {
    final colors = Theme.of(context).colorScheme;
    final controlsEnabled =
        !_sessionIsActive &&
        !_audioOnlyRecordingActive &&
        !_operationInProgress &&
        !_changingLanguages &&
        !_downloadingModel;
    final failureCode = _operationErrorCode ?? _sessionState?.errorCode;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SurfaceCard(
          title: '会话设置',
          icon: Icons.tune_rounded,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('场景类型', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 8),
              SegmentedButton<SubtitleSessionKind>(
                key: const ValueKey('subtitle-session-kind-selector'),
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(
                    value: SubtitleSessionKind.video,
                    label: Text('课程/视频'),
                  ),
                  ButtonSegment(
                    value: SubtitleSessionKind.meeting,
                    label: Text('会议'),
                  ),
                  ButtonSegment(
                    value: SubtitleSessionKind.livestream,
                    label: Text('直播'),
                  ),
                ],
                selected: {_sessionKind},
                onSelectionChanged: controlsEnabled
                    ? (value) => setState(() => _sessionKind = value.single)
                    : null,
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: _languageField(
                      context,
                      '原文语言',
                      _sourceLanguageCode,
                      controlsEnabled,
                    ),
                  ),
                  const SizedBox(width: 12),
                  IconButton(
                    tooltip: '交换原文和译文语言',
                    onPressed: controlsEnabled && _sourceLanguageCode != 'auto'
                        ? () => _changeLanguages(
                            source: _targetLanguageCode,
                            target: _sourceLanguageCode,
                          )
                        : null,
                    icon: const Icon(Icons.swap_horiz_rounded),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _languageField(
                      context,
                      '译文语言',
                      _targetLanguageCode,
                      controlsEnabled,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '英语和普通话使用流式识别；其他可选语种走 Whisper Tiny 分段识别，尚未完成逐语种准确率验收。首次使用建议先用短音频确认。',
                key: const ValueKey('asr-quality-boundary-notice'),
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: colors.onSurfaceVariant),
              ),
            ],
          ),
        ),
        if (includeAudioSourceControls) ...[
          const SizedBox(height: 14),
          _buildAudioSourceControls(context, controlsEnabled: controlsEnabled),
        ],
        const SizedBox(height: 14),
        if (includeNavigationKeys)
          KeyedSubtree(
            key: _recognitionModelSettingsKey,
            child: _buildModelCard(context),
          )
        else
          _buildModelCard(context),
        const SizedBox(height: 14),
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          value: _translationEnabled,
          onChanged: controlsEnabled
              ? (enabled) {
                  setState(() => _translationEnabled = enabled);
                  if (enabled &&
                      _translationSetup == null &&
                      !_loadingTranslationSetup) {
                    unawaited(_loadTranslationSetup());
                  }
                }
              : null,
          title: const Text('生成实时译文'),
          subtitle: const Text('关闭后仍采集声音、识别并保存原文。'),
        ),
        if (_translationEnabled) ...[
          const SizedBox(height: 6),
          _buildTranslationRouteCard(context),
        ],
        if (includeSessionActions) ...[
          const SizedBox(height: 14),
          _buildSessionActions(context),
        ],
        if (_operationLabel != null) ...[
          const SizedBox(height: 10),
          _InlineNotice(
            icon: Icons.hourglass_top_rounded,
            message: _operationLabel!,
          ),
        ],
        if (failureCode != null) ...[
          const SizedBox(height: 10),
          _InlineNotice(
            icon: Icons.error_outline_rounded,
            message: _friendlyError(failureCode),
            isError: true,
          ),
        ],
      ],
    );
  }

  Widget _buildAudioSourceControls(
    BuildContext context, {
    bool? controlsEnabled,
  }) {
    final colors = Theme.of(context).colorScheme;
    final canChangeControls =
        controlsEnabled ??
        (!_sessionIsActive &&
            !_audioOnlyRecordingActive &&
            !_operationInProgress &&
            !_changingLanguages &&
            !_downloadingModel);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '采集来源',
                key: _audioSourceSettingsKey,
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ),
            IconButton(
              tooltip: '刷新音源和麦克风设备',
              onPressed: canChangeControls && !_loadingSources
                  ? _refreshSources
                  : null,
              icon: const Icon(Icons.refresh_rounded),
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
        if (_loadingSources)
          const LinearProgressIndicator()
        else ...[
          CheckboxListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _systemAudioEnabled,
            onChanged: canChangeControls
                ? (enabled) =>
                      setState(() => _systemAudioEnabled = enabled ?? false)
                : null,
            title: const Text('电脑播放声音'),
            subtitle: const Text('系统共享混音；适合对话、课程或会议，歌曲歌词识别不保证。'),
          ),
          if (_sources.isEmpty)
            _InlineNotice(
              icon: Icons.volume_off_outlined,
              message: _sourceLoadError ?? '没有检测到系统播放音源。',
              isError: _sourceLoadError != null,
            )
          else if (Platform.isWindows)
            const _InlineNotice(
              icon: Icons.volume_up_outlined,
              message: '启用后采集 Windows 当前默认输出设备的系统混音。要更换设备，请先停止同传，再到 Windows“系统 > 声音 > 输出”更改默认设备并重新开始。',
            )
          else
            DropdownButtonFormField<String>(
              initialValue: _selectedSourceId,
              isExpanded: true,
              key: ValueKey(
                'subtitle-system-audio-source-${_selectedSourceId ?? 'none'}',
              ),
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.speaker_outlined),
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 12,
                ),
              ),
              items: [
                for (final source in _sources)
                  DropdownMenuItem(
                    value: source.sourceId,
                    child: Text(
                      source.displayName,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: canChangeControls && _systemAudioEnabled
                  ? (value) => setState(() => _selectedSourceId = value)
                  : null,
            ),
          if (_selectedSource case final source?)
            if (!Platform.isWindows) ...[
              const SizedBox(height: 8),
              Text(
                source.description,
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: colors.onSurfaceVariant),
              ),
            ],
          if (Platform.isWindows) ...[
            const SizedBox(height: 8),
            KeyedSubtree(
              key: _microphoneSourceSettingsKey,
              child: Column(
                children: [
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    value: _microphoneCaptureEnabled,
                    onChanged: canChangeControls
                        ? (enabled) => setState(
                            () => _microphoneCaptureEnabled = enabled,
                          )
                        : null,
                    title: const Text('麦克风'),
                    subtitle: const Text('默认关闭；打开后与电脑播放声音分开采集'),
                  ),
                  if (_microphoneCaptureEnabled && _microphoneSources.isEmpty)
                    const _InlineNotice(
                      icon: Icons.mic_off_outlined,
                      message: '没有检测到可用麦克风，请检查 Windows 输入设备和隐私权限。',
                    )
                  else if (_microphoneCaptureEnabled)
                    KeyedSubtree(
                      key: _microphoneDeviceSettingsKey,
                      child: DropdownButtonFormField<String>(
                        key: const ValueKey(
                          'subtitle-microphone-source-settings',
                        ),
                        initialValue: _selectedMicrophoneSourceId,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.mic_none_rounded),
                          labelText: '麦克风设备',
                          border: OutlineInputBorder(),
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 12,
                          ),
                        ),
                        items: [
                          for (final source in _microphoneSources)
                            DropdownMenuItem(
                              value: source.sourceId,
                              child: Text(
                                source.displayName,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: canChangeControls
                            ? (value) => setState(
                                () => _selectedMicrophoneSourceId = value,
                              )
                            : null,
                      ),
                    ),
                ],
              ),
            ),
          ],
          if (_sourceLoadError != null && _sources.isNotEmpty) ...[
            const SizedBox(height: 8),
            _InlineNotice(
              icon: Icons.error_outline_rounded,
              message: _sourceLoadError!,
              isError: true,
            ),
          ],
        ],
      ],
    );
  }

  Widget _languageField(
    BuildContext context,
    String label,
    String value,
    bool enabled,
  ) {
    final isSource = label == '原文语言';
    final supportedTargetCodes =
        TranslationDirection.targetLanguageCodesForSource(_sourceLanguageCode);
    final languages = AsrLanguageRegistry.supportedLanguages
        .where(
          (language) => isSource
              ? true
              : language.code != _sourceLanguageCode &&
                    supportedTargetCodes.contains(language.code),
        )
        .toList(growable: false);
    return KeyedSubtree(
      key: ValueKey('asr-language-$label'),
      child: DropdownButtonFormField<String>(
        key: ValueKey(
          'asr-language-field-$label-$value-$_languageChangeGeneration',
        ),
        isExpanded: true,
        initialValue: value,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 12,
          ),
        ),
        items: [
          for (final language in languages)
            DropdownMenuItem(
              key: ValueKey('asr-language-option-$label-${language.code}'),
              value: language.code,
              child: Text(language.label, overflow: TextOverflow.ellipsis),
            ),
          if (isSource)
            const DropdownMenuItem(
              key: ValueKey('asr-language-option-原文语言-auto'),
              value: 'auto',
              child: Text('自动识别', overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: enabled
            ? (next) {
                if (next == null) return;
                _changeLanguages(
                  source: isSource ? next : _sourceLanguageCode,
                  target: isSource ? _targetLanguageCode : next,
                );
              }
            : null,
      ),
    );
  }

  Widget _buildModelCard(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final installed = _modelInstalled == true;
    final usesMultilingualModel = _usesMultilingualModel(_sourceLanguageCode);
    final modelCheckFailed = _modelErrorCode == 'model_check_failed';
    final downloadCancelled = _modelErrorCode == 'download_cancelled';
    return _SurfaceCard(
      title: '本地语音识别模型',
      icon: Icons.memory_rounded,
      trailing: _checkingModel
          ? const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : _StatusDot(
              label: modelCheckFailed
                  ? '状态未知'
                  : installed
                  ? '已安装'
                  : '未安装',
              icon: modelCheckFailed
                  ? Icons.help_outline_rounded
                  : installed
                  ? Icons.check_circle_outline_rounded
                  : Icons.download_outlined,
              color: modelCheckFailed
                  ? colors.error
                  : installed
                  ? colors.primary
                  : colors.tertiary,
            ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AsrRouteSummary(
            sourceLanguageLabel: _languageName(_sourceLanguageCode),
            routeKind: usesMultilingualModel
                ? AsrRouteKind.multilingualSegmented
                : AsrRouteKind.englishChineseStreaming,
            preparationState: _checkingModel
                ? AsrModelPreparationState.checking
                : modelCheckFailed
                ? AsrModelPreparationState.unknown
                : installed
                ? AsrModelPreparationState.ready
                : AsrModelPreparationState.notInstalled,
          ),
          if (usesMultilingualModel) ...[
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _showMultilingualModelNotice,
                icon: const Icon(Icons.info_outline_rounded, size: 18),
                label: const Text('查看模型来源与许可'),
              ),
            ),
          ],
          if (_modelErrorCode != null) ...[
            const SizedBox(height: 8),
            _InlineNotice(
              icon: downloadCancelled
                  ? Icons.info_outline_rounded
                  : Icons.error_outline_rounded,
              message: _friendlyError(_modelErrorCode!),
              isError: !downloadCancelled,
            ),
          ],
          if (_downloadingModel) ...[
            const SizedBox(height: 12),
            _buildDownloadProgress(context),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => setState(() => _cancelModelDownload = true),
              icon: const Icon(Icons.close_rounded),
              label: const Text('取消下载'),
            ),
          ] else if (modelCheckFailed && !_checkingModel) ...[
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: _checkModelInstallation,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('重新检查'),
            ),
          ] else if (!installed && !_checkingModel) ...[
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: _operationInProgress ? null : _downloadModel,
              icon: const Icon(Icons.download_rounded),
              label: const Text('下载语音模型'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildDownloadProgress(BuildContext context) {
    final progress = _modelDownloadProgress;
    final fraction = progress == null || progress.totalBytes <= 0
        ? null
        : (progress.downloadedBytes / progress.totalBytes).clamp(0.0, 1.0);
    final percent = fraction == null ? null : (fraction * 100).round();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LinearProgressIndicator(value: fraction),
        const SizedBox(height: 6),
        Text(
          progress == null
              ? '正在连接模型源…'
              : '${percent ?? 0}% · ${_formatBytes(progress.downloadedBytes)} / '
                    '${_formatBytes(progress.totalBytes)} · '
                    '${progress.currentFileName}',
          style: Theme.of(context).textTheme.bodySmall,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }

  Widget _buildTranslationRouteCard(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final setup = _translationSetup;
    final isUnavailable =
        _translationSetupError != null ||
        (!_loadingTranslationSetup &&
            setup?.routeKind == SubtitleTranslationRouteKind.unavailable);
    final isRemote =
        setup?.routeKind == SubtitleTranslationRouteKind.remoteProfile;
    final icon = isUnavailable
        ? Icons.warning_amber_rounded
        : isRemote
        ? Icons.cloud_outlined
        : Icons.devices_rounded;
    final color = isUnavailable
        ? colors.error
        : isRemote
        ? colors.tertiary
        : colors.primary;
    final title = _loadingTranslationSetup
        ? '正在读取翻译路径'
        : isUnavailable
        ? '翻译 Provider 不可用'
        : isRemote
        ? '远程翻译 Provider'
        : '本机翻译 Provider';
    final description =
        _translationSetupError ??
        (setup == null
            ? '尚未获得当前语言方向的 Provider 信息。'
            : isUnavailable
            ? setup.detail ?? '请先在翻译设置中配置此语言方向的 Provider。'
            : isRemote
            ? '确认字幕文本将发送到 ${_remoteTargetLabel(setup)}。开始前会再次说明并征求本次确认。'
            : '译文将通过“${setup.providerLabel}”处理。会话沿用已选路径；路由失效时会报告失败，不静默切换。');

    return _SurfaceCard(
      title: title,
      icon: icon,
      trailing: _loadingTranslationSetup
          ? const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : null,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (setup != null && !isUnavailable)
                  Text(
                    setup.providerLabel,
                    style: Theme.of(context).textTheme.labelLarge
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                const SizedBox(height: 3),
                Text(
                  description,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: isUnavailable
                        ? colors.error
                        : colors.onSurfaceVariant,
                  ),
                ),
                if (setup?.detail case final detail?
                    when detail.trim().isNotEmpty && !isUnavailable) ...[
                  const SizedBox(height: 6),
                  Text(detail, style: Theme.of(context).textTheme.bodySmall),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _remoteTargetLabel(LiveSubtitleTranslationSetup setup) {
    final destination = setup.remoteDestinationLabel?.trim();
    return destination == null || destination.isEmpty
        ? setup.providerLabel
        : '${setup.providerLabel}（$destination）';
  }

  Widget _buildSessionActions(
    BuildContext context, {
    bool primaryOnly = false,
    bool secondaryOnly = false,
  }) {
    final status = _sessionStatus;
    final canPause =
        status == SubtitleSessionStatus.preparing ||
        status == SubtitleSessionStatus.capturing;
    final canResume = status == SubtitleSessionStatus.paused;
    final canStop = canPause || canResume;
    final primaryActions = <Widget>[
      if (Platform.isWindows && !_sessionIsActive) ...[
        Container(
          key: const ValueKey('subtitle-selected-audio-source'),
          padding: const EdgeInsets.fromLTRB(10, 7, 6, 7),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
          child: Row(
            children: [
              Icon(
                Icons.volume_up_rounded,
                size: 19,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '电脑播放声',
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                    Text(
                      !_systemAudioEnabled
                          ? '未开启'
                          : _loadingSources
                          ? '正在检测…'
                          : _sourceLoadError != null
                          ? '读取失败，请检查音频设备'
                          : _selectedSource == null
                          ? '未检测到音源'
                          : Platform.isWindows
                          ? 'Windows 默认播放混音'
                          : _selectedSource!.displayName,
                      key: const ValueKey(
                        'subtitle-selected-audio-source-name',
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              TextButton(
                key: const ValueKey('subtitle-change-audio-source'),
                onPressed: _operationInProgress
                    ? null
                    : _openAudioSourceSettings,
                child: Text(
                  Platform.isWindows
                      ? '音源设置'
                      : _selectedSource == null
                      ? '设置'
                      : '更换',
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
      ],
      if (Platform.isWindows &&
          _sessionKind == SubtitleSessionKind.meeting &&
          !_sessionIsActive) ...[
        SwitchListTile.adaptive(
          key: const ValueKey('subtitle-meeting-microphone-toggle'),
          contentPadding: const EdgeInsets.symmetric(horizontal: 8),
          dense: true,
          value: _microphoneCaptureEnabled,
          onChanged: _operationInProgress
              ? null
              : (enabled) =>
                    setState(() => _microphoneCaptureEnabled = enabled),
          secondary: Icon(
            Icons.mic_none_rounded,
            color: _microphoneCaptureEnabled
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          title: const Text('采集本机麦克风'),
          subtitle: Text(
            _microphoneCaptureEnabled
                ? _microphoneSources.isEmpty
                      ? '未检测到麦克风，请检查 Windows 输入设备和隐私权限。'
                      : '电脑播放声和本机发言都会进入字幕。'
                : '当前仅采集电脑播放声，本机发言不会进入字幕。',
          ),
        ),
        if (_microphoneCaptureEnabled) ...[
          Padding(
            padding: const EdgeInsets.only(left: 12, bottom: 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _selectedMicrophoneSource?.displayName ??
                        (_loadingSources
                            ? '正在检测麦克风…'
                            : _sourceLoadError != null
                            ? '读取麦克风失败'
                            : '未检测到可用麦克风'),
                    key: const ValueKey(
                      'subtitle-selected-microphone-source-name',
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                TextButton(
                  key: const ValueKey('subtitle-change-microphone-source'),
                  onPressed: _operationInProgress
                      ? null
                      : _openMicrophoneSourceSettings,
                  child: const Text('麦克风设置'),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 6),
      ],
      FilledButton.icon(
        key: const ValueKey('subtitle-session-start'),
        onPressed: _canStart ? _startSession : null,
        icon: const Icon(Icons.play_arrow_rounded),
        label: const Text('开始同传'),
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              key: const ValueKey('subtitle-session-pause'),
              onPressed: _operationInProgress
                  ? null
                  : canPause
                  ? _pauseSession
                  : canResume
                  ? _resumeSession
                  : null,
              icon: Icon(
                canResume ? Icons.play_arrow_rounded : Icons.pause_rounded,
              ),
              label: Text(canResume ? '继续' : '暂停'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: OutlinedButton.icon(
              key: const ValueKey('subtitle-session-stop'),
              onPressed: _operationInProgress || !canStop ? null : _stopSession,
              icon: const Icon(Icons.stop_rounded),
              label: const Text('停止'),
            ),
          ),
        ],
      ),
      if (_canEnterCompactWindowMode) ...[
        const SizedBox(height: 8),
        OutlinedButton.icon(
          key: const ValueKey('subtitle-enter-compact-mode'),
          onPressed: _operationInProgress ? null : _enterCompactWindowMode,
          icon: const Icon(Icons.picture_in_picture_alt_rounded),
          label: const Text('进入紧凑字幕窗'),
        ),
      ],
      if (!_sessionIsActive) ...[
        const SizedBox(height: 8),
        _buildStartReadinessHint(context),
      ],
      if (_screenRecording) ...[
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.errorContainer
                .withValues(alpha: .45),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '正在录屏',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ),
              OutlinedButton.icon(
                key: const ValueKey('screen-capture-stop-active'),
                onPressed: _screenCaptureBusy ? null : _stopDesktopRecording,
                icon: const Icon(Icons.stop_rounded),
                label: const Text('停止录屏'),
              ),
            ],
          ),
        ),
      ],
    ];
    final secondaryActions = <Widget>[
      if (Platform.isWindows) ...[
        if (widget.screenCapture == null) ...[
          const SizedBox(height: 10),
          const Divider(height: 20),
          Text('独立屏幕录制', style: Theme.of(context).textTheme.labelLarge),
          SwitchListTile.adaptive(
            contentPadding: const EdgeInsets.symmetric(horizontal: 8),
            value: _screenRecordingWithAudio,
            onChanged:
                _screenRecordingActive ||
                    _screenRecordingOperationInProgress ||
                    _operationInProgress
                ? null
                : (enabled) =>
                      setState(() => _screenRecordingWithAudio = enabled),
            secondary: const Icon(Icons.volume_up_outlined),
            title: const Text('把一个选中音源写入视频'),
            subtitle: const Text('默认使用电脑播放声；视频单轨录音，独立录音可另存麦克风 WAV。'),
          ),
          Text(
            '建议选择会议或视频应用窗口；选择整屏会录入该屏幕上所有可见内容，包括可能显示的字幕浮窗。',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          if (_screenRecordingState.targetName.isNotEmpty)
            Text(
              '录制目标：${_screenRecordingState.targetName}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          if (_screenRecordingActive)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                '正在写入 ${_screenRecordingState.videoWidth}×${_screenRecordingState.videoHeight} · '
                '${_screenRecordingState.framesWritten} 帧 · '
                '${(_screenRecordingState.durationUs / 1000000).toStringAsFixed(1)} 秒',
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: Theme.of(context).colorScheme.primary),
              ),
            ),
          if (_screenRecordingState.status == 'failed' &&
              _screenRecordingState.message.isNotEmpty)
            _InlineNotice(
              icon: Icons.error_outline_rounded,
              message: _screenRecordingState.message,
              isError: true,
            ),
          FilledButton.tonalIcon(
            onPressed:
                _screenRecordingOperationInProgress || _operationInProgress
                ? null
                : _screenRecordingActive
                ? _stopScreenRecordingFromUi
                : _screenRecordingState.hasTarget
                ? _startScreenRecording
                : _selectScreenRecordingTarget,
            icon: Icon(
              _screenRecordingActive
                  ? Icons.stop_circle_outlined
                  : _screenRecordingState.hasTarget
                  ? Icons.fiber_manual_record_rounded
                  : Icons.screen_share_outlined,
            ),
            label: Text(
              _screenRecordingActive
                  ? '停止并完成 MP4'
                  : _screenRecordingState.hasTarget
                  ? '开始录屏'
                  : _screenRecordingState.status == 'pickerOpen'
                  ? '正在选择屏幕或窗口…'
                  : '选择屏幕或窗口',
            ),
          ),
          if (!_sessionIsActive &&
              _screenRecordingWithAudio &&
              _screenRecordingState.hasTarget)
            const _InlineNotice(
              icon: Icons.info_outline_rounded,
              message: '要同时同传和录屏，请先开始同传，再开始录屏。录屏先启动时会独立占用音源。',
            ),
          Row(
            children: [
              Expanded(
                child: Text(
                  _screenRecordingState.path.isEmpty
                      ? '本机目录：$_screenRecordingDirectoryPath'
                      : '视频文件：${_screenRecordingState.path}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              TextButton.icon(
                onPressed: _openScreenRecordingsFolder,
                icon: const Icon(Icons.folder_open_outlined),
                label: const Text('打开'),
              ),
            ],
          ),
        ],
        const Divider(height: 20),
        const Divider(height: 20),
        Text('独立音频录制', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 4),
        Text(
          _audioOnlyRecordingDescription,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: _audioOnlyRecordingActive
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        FilledButton.tonalIcon(
          onPressed: _audioOnlyRecordingActive
              ? (_operationInProgress ? null : _stopAudioOnlyRecording)
              : (_canStartAudioOnly ? _startAudioOnlyRecording : null),
          icon: Icon(
            _audioOnlyRecordingActive
                ? Icons.stop_circle_outlined
                : Icons.mic_rounded,
          ),
          label: Text(_audioOnlyRecordingActive ? '停止并保存独立录音' : '仅录音，不开字幕'),
        ),
        if (!_audioOnlyRecordingActive &&
            (_screenRecording || _screenRecordingActive))
          Text(
            '录屏已占用音源。若还要录音或同传，请先停止录屏，再启动音频功能。',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        if (_audioOnlyRecordingActive) ...[
          const SizedBox(height: 4),
          for (final source in _audioOnlySources)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Icon(
                    Icons.circle,
                    size: 9,
                    color: _captureTone(
                      context,
                      _audioOnlySourceStates[_audioOnlySourceIdentity(
                            source.sourceKind,
                            source.sourceId,
                          )]
                          ?.status,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${source.displayName} · ${_captureStatusLabel(_audioOnlySourceStates[_audioOnlySourceIdentity(source.sourceKind, source.sourceId)]?.status)}',
                      style: Theme.of(context).textTheme.bodySmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
        ],
        const SizedBox(height: 8),
        SwitchListTile.adaptive(
          contentPadding: const EdgeInsets.symmetric(horizontal: 8),
          value: _retainSessionAudio,
          onChanged:
              _sessionIsActive ||
                  _audioOnlyRecordingActive ||
                  _operationInProgress
              ? null
              : (enabled) => setState(() => _retainSessionAudio = enabled),
          secondary: const Icon(Icons.mic_none_rounded),
          title: const Text('保留本次采集音频'),
          subtitle: Text(
            _audioRecordingDescription,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        Row(
          children: [
            Expanded(
              child: Text(
                '本机目录：${_audioRecorder.recordingsRootPath}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            TextButton.icon(
              onPressed: _audioRecordingState.sessionId == null
                  ? null
                  : _openAudioRecordingsFolder,
              icon: const Icon(Icons.folder_open_outlined),
              label: const Text('打开'),
            ),
          ],
        ),
      ],
    ];
    if (secondaryOnly) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: secondaryActions,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [...primaryActions, if (!primaryOnly) ...secondaryActions],
    );
  }

  Widget _buildStartReadinessHint(BuildContext context) {
    if (_canStart) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('subtitle-start-readiness'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 6,
        runSpacing: 4,
        children: [
          Icon(Icons.info_outline_rounded, size: 18, color: colors.primary),
          Text(
            _startUnavailableReason,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          TextButton.icon(
            key: const ValueKey('subtitle-open-setup'),
            onPressed: _operationInProgress ? null : _openSessionSetup,
            icon: const Icon(Icons.tune_rounded, size: 16),
            label: const Text('打开设置'),
          ),
        ],
      ),
    );
  }

  String get _startUnavailableReason {
    if (_operationInProgress) return _operationLabel ?? '正在处理当前操作…';
    if (_loadingSources) return '正在读取可用音源…';
    if (_screenStopFuture != null) return '正在完成上一段录屏的收尾，请稍候。';
    if (_screenCaptureBusy) return '画面或录屏正在启动，请完成后再开始同传。';
    if (_screenRecording || _screenRecordingActive) {
      return '录屏已先行启动并独立占用音源。若要同时同传和录屏，请先停止并保存录屏，再开始同传，最后重新启动录屏。';
    }
    if (_screenRecordingOperationInProgress) {
      return '录屏正在准备，请稍后再开始同传。';
    }
    if (!canStartAudioCaptureAfterScreenRecordingCleanup(
      _screenRecordingCleanupStatus,
      audioSubscriptionCleanupUnconfirmed:
          _screenAudioFrameSubscription != null,
    )) {
      return '上一段录屏的音源尚未确认停止；请先重试停止录屏，再启动音频功能。';
    }
    if (_downloadingModel) return '正在下载识别模型…';
    if (_checkingModel) return '正在检查本地语音识别模型…';
    if (_modelInstalled != true) return '先安装本地语音识别模型。';
    if (_selectedCaptureSources.isEmpty) {
      return _sourceLoadError == null ? '请选择电脑播放声音或麦克风。' : '无法读取音源，请在设置中重新加载。';
    }
    if (_changingLanguages || _loadingTranslationSetup) {
      return '正在准备当前语言方向的翻译路径…';
    }
    if (_translationEnabled &&
        (_translationSetupError != null ||
            _translationSetup == null ||
            _translationSetup!.routeKind ==
                SubtitleTranslationRouteKind.unavailable)) {
      return '当前语言方向没有可用的翻译 Provider。';
    }
    if (_audioOnlyRecordingActive) return '请先停止独立录音，再开始同传。';
    return '当前状态暂不可开始，请检查识别与翻译设置。';
  }

  Future<void> _openSessionSetup() => showDialog<void>(
    context: context,
    builder: (dialogContext) {
      final availableHeight = MediaQuery.sizeOf(dialogContext).height;
      return AlertDialog(
        title: const Text(
          '识别与翻译设置',
          key: ValueKey('subtitle-setup-dialog-title'),
        ),
        content: SizedBox(
          width: 680,
          height: (availableHeight * .72).clamp(280.0, 620.0).toDouble(),
          child: SingleChildScrollView(
            child: _buildControls(
              dialogContext,
              includeSessionActions: false,
              includeAudioSourceControls: false,
              includeNavigationKeys: false,
            ),
          ),
        ),
        actions: [
          TextButton(
            key: const ValueKey('subtitle-setup-close'),
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('关闭'),
          ),
        ],
      );
    },
  );

  Widget _buildTranscriptPanel(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final coordinator = _sessionState?.coordinator;
    final segments = _visibleSegments;
    final asrState = _sessionState?.asr;
    final queueState = _sessionState?.translationQueue;
    final saveState = _sessionState?.persistence;
    return _SurfaceCard(
      title: '实时字幕',
      icon: Icons.subtitles_rounded,
      trailing: _canOpenSubtitleWindow
          ? OutlinedButton.icon(
              onPressed: _subtitleWindowBusy ? null : _toggleSubtitleWindow,
              icon: _subtitleWindowBusy
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      _subtitleWindowVisible
                          ? Icons.visibility_off_outlined
                          : Icons.subtitles_rounded,
                    ),
              label: Text(
                _subtitleWindowBusy
                    ? (_subtitleWindowVisible ? '正在隐藏…' : '正在打开…')
                    : (_subtitleWindowVisible ? '隐藏字幕窗' : '打开字幕窗'),
              ),
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildStatusStrip(
            context,
            session: coordinator?.status,
            sourceStates: _sessionState?.sourceStates ?? const [],
            primarySourceStatus: _sessionState?.source?.status,
            asr: asrState,
            queue: queueState,
            save: saveState,
          ),
          if (_subtitleWindowFailure != null) ...[
            const SizedBox(height: 10),
            _buildSubtitleWindowFailureBanner(context),
          ],
          SizedBox(height: segments.isEmpty ? 8 : 14),
          if (segments.isEmpty)
            _buildTranscriptEmptyState(context)
          else
            SizedBox(
              height: 520,
              child: ListView.builder(
                controller: _transcriptScrollController,
                reverse: true,
                itemCount: segments.length,
                itemBuilder: (context, index) {
                  final segment = segments[segments.length - 1 - index];
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _SubtitleSegmentCard(
                      segment: segment,
                      retryEnabled:
                          (segment.translationStatus ==
                                  SubtitleTranslationStatus.failed ||
                              segment.translationStatus ==
                                  SubtitleTranslationStatus.cancelled) &&
                          _sessionCanTranslateAgain &&
                          !_operationInProgress,
                      onRetry: () => _retryTranslation(segment),
                    ),
                  );
                },
              ),
            ),
          if (saveState?.status == SubtitleSessionSaveStatus.failed) ...[
            const SizedBox(height: 12),
            _InlineNotice(
              icon: Icons.save_outlined,
              message: '字幕尚未成功保存到历史。当前已识别内容仍在此会话中，请重试保存。',
              isError: true,
              action: TextButton.icon(
                onPressed: _operationInProgress ? null : _retrySave,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('重试保存'),
              ),
            ),
          ],
          if (queueState != null && queueState.pendingCount > 0) ...[
            const SizedBox(height: 8),
            _InlineNotice(
              icon: Icons.sync_rounded,
              message: '有 ${queueState.pendingCount} 条字幕等待翻译；原文已保留，译文会按队列顺序更新。',
            ),
          ],
          const SizedBox(height: 8),
          Text(
            '字幕时间按本次有效采集时钟计算，不代表第三方播放器时间，也不能用于跳转播放位置。',
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: colors.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _buildSubtitleWindowFailureBanner(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('subtitle-window-failure'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: colors.errorContainer.withValues(alpha: .42),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colors.error.withValues(alpha: .25)),
      ),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded, color: colors.error, size: 19),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _subtitleWindowFailure!,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: colors.onErrorContainer),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: _subtitleWindowBusy ? null : _toggleSubtitleWindow,
            child: const Text('重试'),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusStrip(
    BuildContext context, {
    required SubtitleSessionStatus? session,
    required List<AudioCaptureSourceState> sourceStates,
    required AudioCaptureSourceStatus? primarySourceStatus,
    required StreamingAsrState? asr,
    required SubtitleTranslationQueueState? queue,
    required SubtitleSessionSaveState? save,
  }) {
    final queueLabel = queue == null
        ? '未启动'
        : queue.activeRequestId != null
        ? '翻译中 · ${queue.pendingCount} 待处理'
        : queue.pendingCount > 0
        ? '队列中 · ${queue.pendingCount} 条'
        : '队列空闲';
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _StatusBadge(
          label: '会话 · ${_sessionStatusLabel(session)}',
          icon: _sessionStatusIcon(session),
          tone: _sessionTone(context, session),
        ),
        for (final selectedSource in _selectedCaptureSources)
          _StatusBadge(
            label:
                '${_captureSourceKindLabel(selectedSource.sourceKind)} · ${_captureStatusLabel(_findCaptureState(sourceStates, selectedSource)?.status)}',
            icon: _captureSourceIcon(
              selectedSource.sourceKind,
              _findCaptureState(sourceStates, selectedSource)?.status,
            ),
            tone: _captureTone(
              context,
              _findCaptureState(sourceStates, selectedSource)?.status,
            ),
          ),
        SubtitleAsrStatusIndicator(
          state: asr,
          sourceStatus: primarySourceStatus,
          sessionIsActive: _sessionIsActive,
          errorCodes: _sessionState?.errorCodes ?? const <String>[],
        ),
        _StatusBadge(
          label: '翻译 · $queueLabel',
          icon: queue?.activeRequestId == null
              ? Icons.translate_rounded
              : Icons.sync_rounded,
          tone: Theme.of(context).colorScheme.secondary,
        ),
        _StatusBadge(
          label: '保存 · ${_saveStatusLabel(save)}',
          icon: _saveStatusIcon(save),
          tone: _saveTone(context, save),
        ),
      ],
    );
  }

  Widget _buildTranscriptEmptyState(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final sessionActive = _sessionIsActive;
    if (_hasAsrFailure) {
      return SubtitleAsrFailureNotice(
        onOpenModelSettings: _openRecognitionSettings,
      );
    }
    final sourceStates = _sessionState?.sourceStates ?? const [];
    final sourceActive = sourceStates.any(
      (source) => source.status == AudioCaptureSourceStatus.active,
    );
    final noSignal =
        sourceStates.isNotEmpty &&
        sourceStates.every(
          (source) => source.status == AudioCaptureSourceStatus.noSignal,
        );
    final sourceFailed = sourceStates.any(
      (source) => switch (source.status) {
        AudioCaptureSourceStatus.permissionDenied ||
        AudioCaptureSourceStatus.failed ||
        AudioCaptureSourceStatus.deviceUnavailable ||
        AudioCaptureSourceStatus.deviceDisconnected => true,
        _ => false,
      },
    );
    return Container(
      constraints: BoxConstraints(minHeight: sessionActive ? 300 : 92),
      width: double.infinity,
      padding: EdgeInsets.all(sessionActive ? 28 : 12),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: sessionActive
          ? Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.graphic_eq_rounded, size: 42, color: colors.primary),
                const SizedBox(height: 12),
                Text(
                  sourceActive
                      ? '音源已收到有效帧，正在等待可识别语音'
                      : noSignal
                      ? '暂未收到有效音频'
                      : sourceFailed
                      ? '有采集音源连接失败'
                      : '会话准备中，等待所选音源首帧',
                  style: Theme.of(context).textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 6),
                Text(
                  noSignal
                      ? '请确认播放器或麦克风输入有声音。每个音源的状态会分别显示在上方。'
                      : sourceFailed
                      ? '检查上方出错音源、Windows 输入设备和麦克风隐私权限，再重新开始。'
                      : '确认原文会先显示；语音识别进入临时修订后会在同一条字幕中更新。',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium
                      ?.copyWith(color: colors.onSurfaceVariant),
                ),
              ],
            )
          : Row(
              children: [
                Icon(Icons.subtitles_outlined, size: 32, color: colors.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '开始后，字幕会显示在这里',
                        style: Theme.of(context).textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '临时原文会先显示；只有识别确认后才进入翻译队列。',
                        style: Theme.of(context).textTheme.bodySmall
                            ?.copyWith(color: colors.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  void _openRecognitionSettings() {
    _unifiedSettingsController.expand();
    _languageSettingsController.expand();
    unawaited(_scrollToRecognitionModelSettings());
  }

  void _openAudioSourceSettings() {
    _unifiedSettingsController.expand();
    _recordingSettingsController.expand();
    unawaited(_scrollToAudioSourceSettings());
  }

  void _openMicrophoneSourceSettings() {
    _unifiedSettingsController.expand();
    _recordingSettingsController.expand();
    unawaited(_scrollToMicrophoneSourceSettings());
  }

  Future<void> _scrollToMicrophoneSourceSettings() async {
    await Future<void>.delayed(const Duration(milliseconds: 260));
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    final microphoneDeviceContext = _microphoneDeviceSettingsKey.currentContext;
    final targetContext =
        _microphoneCaptureEnabled && microphoneDeviceContext != null
        ? microphoneDeviceContext
        : _microphoneSourceSettingsKey.currentContext;
    if (targetContext == null || !targetContext.mounted) return;
    await Scrollable.ensureVisible(
      targetContext,
      alignment: 0.18,
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _scrollToAudioSourceSettings() async {
    await Future<void>.delayed(const Duration(milliseconds: 260));
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    final targetContext = _audioSourceSettingsKey.currentContext;
    if (targetContext == null || !targetContext.mounted) return;
    await Scrollable.ensureVisible(
      targetContext,
      alignment: 0.18,
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _scrollToRecognitionModelSettings() async {
    await Future<void>.delayed(const Duration(milliseconds: 260));
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    final targetContext = _recognitionModelSettingsKey.currentContext;
    if (targetContext == null || !targetContext.mounted) return;
    await Scrollable.ensureVisible(
      targetContext,
      alignment: 0.18,
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
    );
  }

  Widget _buildCompactSubtitleView(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final segments = _visibleSegments;
    final source = _selectedSource;
    final active = _sessionIsActive;
    final preferences = _displayPreferences;
    final queue = _sessionState?.translationQueue;
    final queueLabel = queue == null
        ? '未启动'
        : queue.activeRequestId != null
        ? '翻译中'
        : queue.pendingCount > 0
        ? '待处理 ${queue.pendingCount} 条'
        : '空闲';
    return Container(
      color: preferences.highContrast
          ? const Color(0xFF070B10)
          : colors.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        child: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onPanStart: (_) => unawaited(_beginWindowDrag()),
                        child: MouseRegion(
                          cursor: SystemMouseCursors.move,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.subtitles_rounded,
                                  size: 18,
                                  color: preferences.highContrast
                                      ? const Color(0xFF64D7FF)
                                      : colors.primary,
                                ),
                                const SizedBox(width: 7),
                                Expanded(
                                  child: Text(
                                    '译学 · 置顶字幕',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleSmall
                                        ?.copyWith(
                                          fontWeight: FontWeight.w800,
                                          color: preferences.highContrast
                                              ? Colors.white
                                              : null,
                                        ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    PopupMenuButton<_CompactSubtitleSettingAction>(
                      tooltip: '字幕显示设置',
                      padding: EdgeInsets.zero,
                      icon: Icon(
                        Icons.tune_rounded,
                        color: preferences.highContrast ? Colors.white : null,
                      ),
                      onSelected: _applyCompactSubtitleSetting,
                      itemBuilder: (context) =>
                          _buildCompactSubtitleSettingItems(context),
                    ),
                    if (active)
                      IconButton(
                        tooltip: _sessionStatus == SubtitleSessionStatus.paused
                            ? '继续'
                            : '暂停',
                        visualDensity: VisualDensity.compact,
                        onPressed: _operationInProgress
                            ? null
                            : _sessionStatus == SubtitleSessionStatus.paused
                            ? _resumeSession
                            : _pauseSession,
                        icon: Icon(
                          _sessionStatus == SubtitleSessionStatus.paused
                              ? Icons.play_arrow_rounded
                              : Icons.pause_rounded,
                          color: preferences.highContrast ? Colors.white : null,
                        ),
                      ),
                    if (active)
                      IconButton(
                        tooltip: '停止并保存',
                        visualDensity: VisualDensity.compact,
                        onPressed: _operationInProgress ? null : _stopSession,
                        icon: Icon(
                          Icons.stop_rounded,
                          color: preferences.highContrast ? Colors.white : null,
                        ),
                      ),
                    if (_sessionState?.persistence?.status ==
                        SubtitleSessionSaveStatus.failed)
                      IconButton(
                        tooltip: '重试保存字幕',
                        visualDensity: VisualDensity.compact,
                        onPressed: _operationInProgress ? null : _retrySave,
                        icon: Icon(
                          Icons.save_outlined,
                          color: preferences.highContrast ? Colors.white : null,
                        ),
                      ),
                    IconButton(
                      tooltip: '退出置顶模式并恢复主工作台',
                      visualDensity: VisualDensity.compact,
                      onPressed: _operationInProgress
                          ? null
                          : _exitCompactWindowMode,
                      icon: Icon(
                        Icons.close_fullscreen_rounded,
                        color: preferences.highContrast ? Colors.white : null,
                      ),
                    ),
                  ],
                ),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        source == null
                            ? _platformSourceLabel
                            : '${_platformSourceLabel} · ${source.displayName}',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: preferences.highContrast
                              ? const Color(0xFFCFD8E3)
                              : colors.onSurfaceVariant,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  '字幕 · $_subtitleSourceLanguageLabel → ${_languageLabel(_targetLanguageCode)} · ${preferences.mode.label}',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: preferences.highContrast
                        ? const Color(0xFFAAB6C4)
                        : colors.onSurfaceVariant,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 5),
                Wrap(
                  spacing: 12,
                  runSpacing: 4,
                  children: [
                    _StatusDot(
                      label:
                          '音源 · ${_selectedCaptureStatusLabel(_sessionState)}',
                      icon: _selectedCaptureStatusIcon(_sessionState),
                      color: _captureTone(
                        context,
                        _sessionState?.source?.status,
                      ),
                      highContrast: preferences.highContrast,
                    ),
                    SubtitleAsrStatusIndicator(
                      state: _sessionState?.asr,
                      sourceStatus: _sessionState?.source?.status,
                      sessionIsActive: _sessionIsActive,
                      errorCodes: _sessionState?.errorCodes ?? const <String>[],
                      compact: true,
                      highContrast: preferences.highContrast,
                    ),
                    _StatusDot(
                      label: '翻译 · $queueLabel',
                      icon: queue?.activeRequestId == null
                          ? Icons.translate_rounded
                          : Icons.sync_rounded,
                      color: colors.secondary,
                      highContrast: preferences.highContrast,
                    ),
                    _StatusDot(
                      label:
                          '保存 · ${_saveStatusLabel(_sessionState?.persistence)}',
                      icon: _saveStatusIcon(_sessionState?.persistence),
                      color: _saveTone(context, _sessionState?.persistence),
                      highContrast: preferences.highContrast,
                    ),
                  ],
                ),
                const Divider(height: 16),
                Expanded(
                  child: segments.isEmpty
                      ? Center(
                          child: Text(
                            active ? '正在等待可识别语音…' : '此会话还没有字幕',
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(
                                  color: preferences.highContrast
                                      ? const Color(0xFFCFD8E3)
                                      : colors.onSurfaceVariant,
                                ),
                          ),
                        )
                      : ListView.builder(
                          reverse: true,
                          itemCount: min(segments.length, 12),
                          itemBuilder: (context, index) {
                            final segment =
                                segments[segments.length - 1 - index];
                            return _CompactSubtitleSegment(
                              segment: segment,
                              mode: preferences.mode,
                              fontScale: preferences.fontScale,
                              colorPreset: preferences.colorPreset,
                              highContrast: preferences.highContrast,
                              retryEnabled:
                                  (segment.translationStatus ==
                                          SubtitleTranslationStatus.failed ||
                                      segment.translationStatus ==
                                          SubtitleTranslationStatus
                                              .cancelled) &&
                                  _sessionCanTranslateAgain &&
                                  !_operationInProgress,
                              onRetry: () => _retryTranslation(segment),
                            );
                          },
                        ),
                ),
              ],
            ),
            Positioned(
              right: 0,
              bottom: 0,
              child: MouseRegion(
                cursor: SystemMouseCursors.resizeUpLeftDownRight,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanStart: _beginWindowResize,
                  onPanUpdate: _updateWindowResize,
                  onPanEnd: (_) => _finishWindowResize(),
                  onPanCancel: _finishWindowResize,
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(
                      Icons.open_in_full_rounded,
                      size: 15,
                      color: preferences.highContrast
                          ? const Color(0xFFAAB6C4)
                          : colors.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<PopupMenuEntry<_CompactSubtitleSettingAction>>
  _buildCompactSubtitleSettingItems(BuildContext context) {
    final preferences = _displayPreferences;
    Widget selectionMark(bool selected) => SizedBox(
      width: 24,
      child: selected ? const Icon(Icons.check_rounded, size: 18) : null,
    );

    return [
      const PopupMenuItem<_CompactSubtitleSettingAction>(
        enabled: false,
        child: Text('字幕内容'),
      ),
      for (final mode in SubtitleDisplayMode.values)
        PopupMenuItem<_CompactSubtitleSettingAction>(
          value: switch (mode) {
            SubtitleDisplayMode.bilingual =>
              _CompactSubtitleSettingAction.bilingual,
            SubtitleDisplayMode.sourceOnly =>
              _CompactSubtitleSettingAction.sourceOnly,
            SubtitleDisplayMode.translatedOnly =>
              _CompactSubtitleSettingAction.translatedOnly,
          },
          child: Row(
            children: [
              selectionMark(preferences.mode == mode),
              Text(mode.label),
            ],
          ),
        ),
      const PopupMenuDivider(),
      const PopupMenuItem<_CompactSubtitleSettingAction>(
        enabled: false,
        child: Text('字幕字号'),
      ),
      for (final scale in SubtitleFontScale.values)
        PopupMenuItem<_CompactSubtitleSettingAction>(
          value: switch (scale) {
            SubtitleFontScale.compact =>
              _CompactSubtitleSettingAction.fontCompact,
            SubtitleFontScale.standard =>
              _CompactSubtitleSettingAction.fontStandard,
            SubtitleFontScale.large => _CompactSubtitleSettingAction.fontLarge,
          },
          child: Row(
            children: [
              selectionMark(preferences.fontScale == scale),
              Text(scale.label),
            ],
          ),
        ),
      const PopupMenuDivider(),
      const PopupMenuItem<_CompactSubtitleSettingAction>(
        enabled: false,
        child: Text('字幕颜色'),
      ),
      for (final preset in SubtitleColorPreset.values)
        PopupMenuItem<_CompactSubtitleSettingAction>(
          value: switch (preset) {
            SubtitleColorPreset.ice => _CompactSubtitleSettingAction.colorIce,
            SubtitleColorPreset.amber =>
              _CompactSubtitleSettingAction.colorAmber,
            SubtitleColorPreset.mint => _CompactSubtitleSettingAction.colorMint,
            SubtitleColorPreset.rose => _CompactSubtitleSettingAction.colorRose,
          },
          child: Row(
            children: [
              selectionMark(preferences.colorPreset == preset),
              Icon(
                Icons.circle,
                size: 12,
                color: Color(
                  preferences.highContrast
                      ? preset.darkAccentArgb
                      : preset.lightAccentArgb,
                ),
              ),
              const SizedBox(width: 8),
              Text(preset.label),
            ],
          ),
        ),
      const PopupMenuDivider(),
      PopupMenuItem<_CompactSubtitleSettingAction>(
        value: _CompactSubtitleSettingAction.toggleHighContrast,
        child: Row(
          children: [
            selectionMark(preferences.highContrast),
            const Text('高对比字幕背景'),
          ],
        ),
      ),
      const PopupMenuDivider(),
      const PopupMenuItem<_CompactSubtitleSettingAction>(
        enabled: false,
        child: Text('字幕窗透明度'),
      ),
      for (final (opacity, action, label)
          in const <(double, _CompactSubtitleSettingAction, String)>[
            (0.72, _CompactSubtitleSettingAction.opacityLight, '更透明 · 72%'),
            (0.82, _CompactSubtitleSettingAction.opacityBalanced, '均衡 · 82%'),
            (0.92, _CompactSubtitleSettingAction.opacityClear, '更清晰 · 92%'),
          ])
        PopupMenuItem<_CompactSubtitleSettingAction>(
          value: action,
          child: Row(
            children: [
              selectionMark((preferences.windowOpacity - opacity).abs() < 0.01),
              Text(label),
            ],
          ),
        ),
    ];
  }

  void _applyCompactSubtitleSetting(_CompactSubtitleSettingAction action) {
    final preferences = _displayPreferences;
    final updated = switch (action) {
      _CompactSubtitleSettingAction.bilingual => preferences.copyWith(
        mode: SubtitleDisplayMode.bilingual,
      ),
      _CompactSubtitleSettingAction.sourceOnly => preferences.copyWith(
        mode: SubtitleDisplayMode.sourceOnly,
      ),
      _CompactSubtitleSettingAction.translatedOnly => preferences.copyWith(
        mode: SubtitleDisplayMode.translatedOnly,
      ),
      _CompactSubtitleSettingAction.fontCompact => preferences.copyWith(
        fontScale: SubtitleFontScale.compact,
      ),
      _CompactSubtitleSettingAction.fontStandard => preferences.copyWith(
        fontScale: SubtitleFontScale.standard,
      ),
      _CompactSubtitleSettingAction.fontLarge => preferences.copyWith(
        fontScale: SubtitleFontScale.large,
      ),
      _CompactSubtitleSettingAction.colorIce => preferences.copyWith(
        colorPreset: SubtitleColorPreset.ice,
      ),
      _CompactSubtitleSettingAction.colorAmber => preferences.copyWith(
        colorPreset: SubtitleColorPreset.amber,
      ),
      _CompactSubtitleSettingAction.colorMint => preferences.copyWith(
        colorPreset: SubtitleColorPreset.mint,
      ),
      _CompactSubtitleSettingAction.colorRose => preferences.copyWith(
        colorPreset: SubtitleColorPreset.rose,
      ),
      _CompactSubtitleSettingAction.toggleHighContrast => preferences.copyWith(
        highContrast: !preferences.highContrast,
      ),
      _CompactSubtitleSettingAction.opacityLight => preferences.copyWith(
        windowOpacity: 0.72,
      ),
      _CompactSubtitleSettingAction.opacityBalanced => preferences.copyWith(
        windowOpacity: 0.82,
      ),
      _CompactSubtitleSettingAction.opacityClear => preferences.copyWith(
        windowOpacity: 0.92,
      ),
    };
    _updateDisplayPreferences(updated);
  }

  String get _subtitleSourceLanguageLabel {
    if (_sourceLanguageCode != 'auto') {
      return _languageLabel(_sourceLanguageCode);
    }
    final segments = _visibleSegments;
    return segments.isEmpty
        ? '自动识别'
        : _transcriptLanguageLabel(segments.last.transcript.languageCode);
  }

  String _languageLabel(String code) =>
      code == 'auto' ? '自动识别' : AsrLanguageRegistry.displayLabel(code) ?? code;

  String get _platformSourceLabel =>
      Platform.isWindows ? '所选系统播放声与可选麦克风' : '所选显示器关联音频';

  String _sessionStatusLabel(SubtitleSessionStatus? status) => switch (status) {
    SubtitleSessionStatus.idle => '未开始',
    SubtitleSessionStatus.preparing => '准备中',
    SubtitleSessionStatus.capturing => '运行中',
    SubtitleSessionStatus.paused => '已暂停',
    SubtitleSessionStatus.stopping => '正在停止',
    SubtitleSessionStatus.stopped => '已停止',
    SubtitleSessionStatus.failed => '失败',
    null => '未开始',
  };

  IconData _sessionStatusIcon(SubtitleSessionStatus? status) =>
      switch (status) {
        SubtitleSessionStatus.capturing => Icons.play_circle_outline_rounded,
        SubtitleSessionStatus.paused => Icons.pause_circle_outline_rounded,
        SubtitleSessionStatus.failed => Icons.error_outline_rounded,
        _ => Icons.circle_outlined,
      };

  Color _sessionTone(BuildContext context, SubtitleSessionStatus? status) {
    final colors = Theme.of(context).colorScheme;
    return status == SubtitleSessionStatus.failed
        ? colors.error
        : colors.primary;
  }

  String _captureStatusLabel(AudioCaptureSourceStatus? status) =>
      switch (status) {
        AudioCaptureSourceStatus.notRequested || null => '未连接',
        AudioCaptureSourceStatus.requestingAccess => '请求系统权限',
        AudioCaptureSourceStatus.ready => '音源已就绪',
        AudioCaptureSourceStatus.waitingForFirstFrame => '等待首帧',
        AudioCaptureSourceStatus.active => '已收到有效帧',
        AudioCaptureSourceStatus.noSignal => '暂时无音频数据',
        AudioCaptureSourceStatus.paused => '已暂停',
        AudioCaptureSourceStatus.permissionDenied => '权限被拒绝',
        AudioCaptureSourceStatus.deviceUnavailable => '音源不可用',
        AudioCaptureSourceStatus.deviceDisconnected => '音源已断开',
        AudioCaptureSourceStatus.stopped => '已停止',
        AudioCaptureSourceStatus.failed => '采集失败',
      };

  AudioCaptureSourceState? _findCaptureState(
    Iterable<AudioCaptureSourceState> states,
    DesktopAudioCaptureSource source,
  ) {
    for (final state in states) {
      if (state.sourceId == source.sourceId &&
          state.sourceKind == source.sourceKind) {
        return state;
      }
    }
    return null;
  }

  String _selectedCaptureStatusLabel(LiveSubtitleSessionState? sessionState) {
    final sources = _selectedCaptureSources;
    if (sources.isEmpty) {
      return _captureStatusLabel(sessionState?.source?.status);
    }
    final states =
        sessionState?.sourceStates ?? const <AudioCaptureSourceState>[];
    return sources
        .map((source) {
          final status = _findCaptureState(states, source)?.status;
          return '${_captureSourceKindLabel(source.sourceKind)} ${_captureStatusLabel(status)}';
        })
        .join(' · ');
  }

  IconData _selectedCaptureStatusIcon(LiveSubtitleSessionState? state) {
    final sources = _selectedCaptureSources;
    if (sources.isEmpty) return Icons.speaker_outlined;
    final states = state?.sourceStates ?? const <AudioCaptureSourceState>[];
    final first = sources.first;
    return _captureSourceIcon(
      first.sourceKind,
      _findCaptureState(states, first)?.status,
    );
  }

  IconData _captureSourceIcon(
    SubtitleAudioSourceKind kind,
    AudioCaptureSourceStatus? status,
  ) {
    if (status == AudioCaptureSourceStatus.permissionDenied ||
        status == AudioCaptureSourceStatus.failed ||
        status == AudioCaptureSourceStatus.deviceUnavailable ||
        status == AudioCaptureSourceStatus.deviceDisconnected) {
      return Icons.error_outline_rounded;
    }
    if (status == AudioCaptureSourceStatus.active) {
      return Icons.graphic_eq_rounded;
    }
    if (status == AudioCaptureSourceStatus.paused) {
      return Icons.pause_circle_outline_rounded;
    }
    return switch (kind) {
      SubtitleAudioSourceKind.microphone => Icons.mic_none_rounded,
      SubtitleAudioSourceKind.applicationOutput => Icons.apps_rounded,
      SubtitleAudioSourceKind.systemOutput => Icons.speaker_outlined,
    };
  }

  String _captureSourceKindLabel(SubtitleAudioSourceKind kind) =>
      switch (kind) {
        SubtitleAudioSourceKind.systemOutput => '系统声',
        SubtitleAudioSourceKind.applicationOutput => '应用声',
        SubtitleAudioSourceKind.microphone => '麦克风',
      };

  Color _captureTone(BuildContext context, AudioCaptureSourceStatus? status) {
    final colors = Theme.of(context).colorScheme;
    return switch (status) {
      AudioCaptureSourceStatus.active => colors.primary,
      AudioCaptureSourceStatus.permissionDenied ||
      AudioCaptureSourceStatus.failed ||
      AudioCaptureSourceStatus.deviceUnavailable ||
      AudioCaptureSourceStatus.deviceDisconnected => colors.error,
      AudioCaptureSourceStatus.noSignal ||
      AudioCaptureSourceStatus.waitingForFirstFrame => colors.tertiary,
      _ => colors.onSurfaceVariant,
    };
  }

  String _saveStatusLabel(SubtitleSessionSaveState? state) =>
      switch (state?.status) {
        SubtitleSessionSaveStatus.idle ||
        null => _sessionIsActive ? '等待写入' : '尚未保存',
        SubtitleSessionSaveStatus.saving => '写入中',
        SubtitleSessionSaveStatus.saved => '已保存',
        SubtitleSessionSaveStatus.failed => '保存失败',
      };

  IconData _saveStatusIcon(SubtitleSessionSaveState? state) =>
      switch (state?.status) {
        SubtitleSessionSaveStatus.saved => Icons.check_circle_outline_rounded,
        SubtitleSessionSaveStatus.failed => Icons.error_outline_rounded,
        SubtitleSessionSaveStatus.saving => Icons.sync_rounded,
        _ => Icons.save_outlined,
      };

  Color _saveTone(BuildContext context, SubtitleSessionSaveState? state) {
    final colors = Theme.of(context).colorScheme;
    return switch (state?.status) {
      SubtitleSessionSaveStatus.saved => colors.primary,
      SubtitleSessionSaveStatus.failed => colors.error,
      SubtitleSessionSaveStatus.saving => colors.tertiary,
      _ => colors.onSurfaceVariant,
    };
  }

  String _friendlyError(String code) => switch (code) {
    'desktop_only' => '当前平台不支持桌面系统音源。',
    'model_check_failed' => '读取本地语音模型状态失败，请重试。',
    'download_timeout' => '模型下载超时，请检查网络后重试。',
    'download_io_error' || 'download_failed' => '模型下载失败，请检查网络和磁盘空间后重试。',
    'download_http_error' => '模型源暂时无法提供文件，请稍后重试。',
    'download_hash_mismatch' => '模型文件校验失败，未安装该文件；请重试下载。',
    'download_size_mismatch' => '模型文件大小与清单不一致，未安装该文件；请重试下载。',
    'download_redirect_rejected' => '模型源重定向不安全，已拒绝下载。',
    'destination_conflict' => '模型目录已存在但文件不匹配；请检查本机模型目录后再重试。',
    'destination_unavailable' => '无法创建本机模型目录，请检查文件权限和磁盘空间。',
    'download_cancelled' => '已取消模型下载。',
    'model_invalid' || 'model_unavailable' => '语音模型不可用，请重新安装或下载模型。',
    'translation_route_unavailable' => '当前语言方向没有可用的翻译 Provider。',
    'unsupported_language_pair' => '当前 Provider 不支持所选语言方向。',
    'provider_route_changed' => '翻译 Provider 配置发生变化，会话已停止使用原路径。',
    'ambiguous_translation_provider' => '多个启用的翻译配置同时指定了翻译用途，请在模型与服务中选择唯一配置。',
    'audio_access_denied' || 'accessDenied' => '系统音频权限未授权，请在系统设置中允许后重试。',
    'audio_device_unavailable' => '所选系统音源不可用，请刷新音源列表。',
    'audio_device_disconnected' => '系统音源已断开，请重新连接后开始新会话。',
    'audio_source_stopped' ||
    'audio_capture_stream_closed' => '系统音频流意外结束，请检查系统播放状态并重新开始。',
    'audio_noSignal' || 'noSignal' => '当前系统音源没有可用音频数据。',
    'asr_audioBackpressure' => '识别运行时处理不过来，已停止本次会话以避免丢失音频。',
    'asr_modelUnavailable' => '本地语音模型未安装，请先下载模型。',
    'asr_modelInvalid' => '本地语音模型文件校验失败，请重新下载模型。',
    'asr_open_timeout' => '语音识别运行时启动超时；尚未开始采音，请检查模型状态后重试。',
    'asr_ready_timeout' => '语音识别未能及时就绪；尚未开始采音，请检查本地模型和系统负载后重试。',
    'asr_runtimeUnavailable' => '当前平台的语音识别运行时不可用。',
    'asr_runtimeInitializationFailed' ||
    'asr_recognitionFailed' => '语音识别运行时启动或处理失败，请重新开始会话。',
    'asr_audioFormatUnsupported' => '当前系统音频格式无法交给识别运行时处理。',
    'asr_workerExited' ||
    'asr_workerTimedOut' ||
    'asr_workerProtocolError' => '本地识别工作进程异常结束，请重新开始会话。',
    'storage_io_failed' ||
    'storage_write_failed' ||
    'storage_initial_write_failed' => '字幕本机保存失败，可重试保存。',
    'storage_close_failed' ||
    'coordinator_stop_failed' => '停止会话时未能完成字幕保存，可重试保存。',
    'asr_close_failed' => '识别收尾未完整完成，请检查最后一条字幕和保存状态。',
    'session_not_started' => '字幕会话尚未启动。',
    'session_not_active' => '当前字幕会话已不在运行状态。',
    'session_not_paused' => '当前字幕会话没有处于暂停状态。',
    'session_start_failed' => '字幕会话启动失败，请检查音源和本地模型状态。',
    'session_pause_failed' => '暂停失败，请重试或停止会话。',
    'session_resume_failed' => '恢复失败，请重试或停止会话。',
    'session_stop_failed' => '停止会话时遇到问题，请查看保存状态。',
    'translation_retry_failed' => '翻译重试失败，请稍后再试。',
    _ => '操作失败（$code），请检查状态后重试。',
  };

  static String _formatBytes(int bytes) {
    const bytesPerKilobyte = 1000;
    const bytesPerMegabyte = bytesPerKilobyte * 1000;
    if (bytes < bytesPerKilobyte) return '$bytes B';
    if (bytes < bytesPerMegabyte) {
      return '${(bytes / bytesPerKilobyte).toStringAsFixed(1)} KB';
    }
    return '${(bytes / bytesPerMegabyte).toStringAsFixed(1)} MB';
  }
}

final class _WindowManagerCompactSubtitleWindowActions
    implements CompactSubtitleWindowActions {
  const _WindowManagerCompactSubtitleWindowActions();

  WindowManager get _manager => windowManager;

  @override
  Future<Rect> getBounds() => _manager.getBounds();

  @override
  Future<bool> isAlwaysOnTop() => _manager.isAlwaysOnTop();

  @override
  Future<bool> isMaximized() => _manager.isMaximized();

  @override
  Future<bool> isResizable() => _manager.isResizable();

  @override
  Future<void> maximize() => _manager.maximize();

  @override
  Future<void> setAlwaysOnTop(bool value) => _manager.setAlwaysOnTop(value);

  @override
  Future<void> setBounds(Rect? bounds, {Offset? position, Size? size}) =>
      _manager.setBounds(bounds, position: position, size: size);

  @override
  Future<void> setMinimumSize(Size size) => _manager.setMinimumSize(size);

  @override
  Future<void> setResizable(bool value) => _manager.setResizable(value);

  @override
  Future<void> setSize(Size size) => _manager.setSize(size);

  @override
  Future<void> startDragging() => _manager.startDragging();

  @override
  Future<void> unmaximize() => _manager.unmaximize();
}

final class _WorkbenchFailure implements Exception {
  const _WorkbenchFailure(this.code);

  final String code;
}

/// Non-blaming empty state shown when audio capture and speech recognition
/// have different outcomes. Capture status remains visible in the status strip.
final class SubtitleAsrFailureNotice extends StatelessWidget {
  const SubtitleAsrFailureNotice({this.onOpenModelSettings, super.key});

  final VoidCallback? onOpenModelSettings;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('subtitle-asr-failure-empty-state'),
      constraints: const BoxConstraints(minHeight: 92),
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Row(
        children: [
          Icon(Icons.record_voice_over_outlined, size: 32, color: colors.error),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '语音识别暂不可用',
                  style: Theme.of(context).textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(
                  '音源采集状态仍单独显示；可检查识别模型后重新开始同传。',
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: colors.onSurfaceVariant),
                ),
                if (onOpenModelSettings != null) ...[
                  const SizedBox(height: 4),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      key: const ValueKey('subtitle-open-recognition-settings'),
                      onPressed: onOpenModelSettings,
                      icon: const Icon(Icons.tune_rounded, size: 16),
                      label: const Text('检查语音模型'),
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

final class _SurfaceCard extends StatelessWidget {
  const _SurfaceCard({
    required this.title,
    required this.icon,
    required this.child,
    this.trailing,
  });

  final String title;
  final IconData icon;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      color: colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: colors.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(icon, size: 20, color: colors.primary),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                if (trailing != null) trailing!,
              ],
            ),
            const SizedBox(height: 14),
            child,
          ],
        ),
      ),
    );
  }
}

/// Shared recognition status for the normal and compact subtitle workbench.
/// A session error can outlive the recognizer object while cleanup closes it.
final class SubtitleAsrStatusIndicator extends StatelessWidget {
  const SubtitleAsrStatusIndicator({
    required this.state,
    required this.sourceStatus,
    required this.sessionIsActive,
    required this.errorCodes,
    this.compact = false,
    this.highContrast = false,
    super.key,
  });

  final StreamingAsrState? state;
  final AudioCaptureSourceStatus? sourceStatus;
  final bool sessionIsActive;
  final List<String> errorCodes;
  final bool compact;
  final bool highContrast;

  @override
  Widget build(BuildContext context) {
    final hasFailure = _subtitleAsrHasFailure(state, errorCodes);
    final label = hasFailure
        ? '暂不可用'
        : state == null
        ? (sessionIsActive ? '准备中' : '未启动')
        : switch (state!.status) {
            StreamingAsrStatus.loading => '模型加载中',
            StreamingAsrStatus.ready =>
              sourceStatus == AudioCaptureSourceStatus.active ? '等待语音' : '已就绪',
            StreamingAsrStatus.recognizing =>
              state!.hasRecognizedSpeech ? '正在识别' : '已接收音频',
            StreamingAsrStatus.flushing => '确认片段中',
            StreamingAsrStatus.closed => '已关闭',
            StreamingAsrStatus.failed => '暂不可用',
          };
    final icon = hasFailure
        ? Icons.error_outline_rounded
        : switch (state?.status) {
            StreamingAsrStatus.recognizing => Icons.hearing_rounded,
            StreamingAsrStatus.flushing => Icons.hourglass_top_rounded,
            _ => Icons.record_voice_over_outlined,
          };
    final colors = Theme.of(context).colorScheme;
    final tone = hasFailure ? colors.error : colors.secondary;
    final fullLabel = '识别 · $label';
    return compact
        ? _StatusDot(
            label: fullLabel,
            icon: icon,
            color: tone,
            highContrast: highContrast,
          )
        : _StatusBadge(label: fullLabel, icon: icon, tone: tone);
  }
}

bool _subtitleAsrHasFailure(
  StreamingAsrState? state,
  Iterable<String> errorCodes,
) =>
    state?.status == StreamingAsrStatus.failed ||
    errorCodes.any((code) => code.startsWith('asr_'));

final class _StatusBadge extends StatelessWidget {
  const _StatusBadge({
    required this.label,
    required this.icon,
    required this.tone,
  });

  final String label;
  final IconData icon;
  final Color tone;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: .10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: tone.withValues(alpha: .3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: tone),
          const SizedBox(width: 6),
          Text(label, style: Theme.of(context).textTheme.labelMedium),
        ],
      ),
    );
  }
}

final class _StatusDot extends StatelessWidget {
  const _StatusDot({
    required this.label,
    required this.icon,
    required this.color,
    this.highContrast = false,
  });

  final String label;
  final IconData icon;
  final Color color;
  final bool highContrast;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 5),
        Text(
          label,
          style: Theme.of(context).textTheme.labelMedium
              ?.copyWith(color: highContrast ? Colors.white : color),
        ),
      ],
    );
  }
}

final class _InlineNotice extends StatelessWidget {
  const _InlineNotice({
    required this.icon,
    required this.message,
    this.isError = false,
    this.action,
  });

  final IconData icon;
  final String message;
  final bool isError;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final tone = isError ? colors.error : colors.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: (isError ? colors.errorContainer : colors.surfaceContainerLow)
            .withValues(alpha: isError ? .62 : .8),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isError
              ? colors.error.withValues(alpha: .35)
              : colors.outlineVariant,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(icon, size: 18, color: tone),
          const SizedBox(width: 8),
          Expanded(
            child: Text(message, style: Theme.of(context).textTheme.bodySmall),
          ),
          if (action != null) ...[const SizedBox(width: 8), action!],
        ],
      ),
    );
  }
}

final class _SubtitleSegmentCard extends StatelessWidget {
  const _SubtitleSegmentCard({
    required this.segment,
    required this.retryEnabled,
    required this.onRetry,
  });

  final SubtitleSegment segment;
  final bool retryEnabled;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final transcript = segment.transcript;
    final isFinal = transcript.isFinal;
    final failed =
        segment.translationStatus == SubtitleTranslationStatus.failed;
    final canRetry =
        segment.translationStatus == SubtitleTranslationStatus.failed ||
        segment.translationStatus == SubtitleTranslationStatus.cancelled;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: failed
              ? colors.error.withValues(alpha: .55)
              : colors.outlineVariant,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _StatusDot(
                label: isFinal ? '确认字幕' : '临时识别',
                icon: isFinal
                    ? Icons.check_circle_outline_rounded
                    : Icons.edit_note_rounded,
                color: isFinal ? colors.primary : colors.tertiary,
              ),
              const SizedBox(width: 10),
              Text(
                '${_formatTimeline(transcript.startMs)} – ${_formatTimeline(transcript.endMs)}',
                style: Theme.of(context).textTheme.labelSmall
                    ?.copyWith(color: colors.onSurfaceVariant),
              ),
              const SizedBox(width: 10),
              SubtitleTranscriptLanguageBadge(
                languageCode: transcript.languageCode,
              ),
              const Spacer(),
              Tooltip(
                message:
                    segment.translationStatus ==
                        SubtitleTranslationStatus.skippedUnsupportedLanguage
                    ? '语种未识别，原文保留'
                    : _translationStatusLabel(segment.translationStatus),
                child: Text(
                  _translationStatusLabel(segment.translationStatus),
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: failed ? colors.error : colors.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            transcript.text.isEmpty
                ? '（空白修订）'
                : formatSubtitleTextForDisplay(
                    transcript.text,
                    languageCode: transcript.languageCode,
                  ),
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              color: isFinal ? colors.onSurface : colors.onSurfaceVariant,
              fontWeight: isFinal ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.fromLTRB(11, 9, 11, 9),
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    segment.translatedText ??
                        _translationPlaceholder(segment.translationStatus),
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: segment.translatedText == null
                          ? colors.onSurfaceVariant
                          : colors.onSurface,
                    ),
                  ),
                ),
                if (canRetry)
                  IconButton(
                    tooltip: retryEnabled ? '重试此片段翻译' : '请在会话运行或暂停时重试',
                    visualDensity: VisualDensity.compact,
                    onPressed: retryEnabled ? onRetry : null,
                    icon: const Icon(Icons.refresh_rounded),
                  ),
              ],
            ),
          ),
          if (segment.translationErrorCode case final errorCode?) ...[
            const SizedBox(height: 5),
            Text(
              '翻译失败：${_friendlyTranslationError(errorCode)}',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: colors.error),
            ),
          ],
        ],
      ),
    );
  }

  static String _translationPlaceholder(SubtitleTranslationStatus status) =>
      switch (status) {
        SubtitleTranslationStatus.awaitingFinal => '等待识别确认后翻译',
        SubtitleTranslationStatus.awaitingQueue => '等待翻译队列接收',
        SubtitleTranslationStatus.queued => '已进入翻译队列',
        SubtitleTranslationStatus.translating => '正在翻译…',
        SubtitleTranslationStatus.translated => '译文为空',
        SubtitleTranslationStatus.failed => '译文暂不可用，原文已保留',
        SubtitleTranslationStatus.cancelled => '翻译已取消，可重试',
        SubtitleTranslationStatus.skippedEmpty => '空白片段未翻译',
        SubtitleTranslationStatus.skippedDisabled => '未启用翻译，原文已保存',
        SubtitleTranslationStatus.skippedUnsupportedLanguage => '语种未识别，原文保留',
        SubtitleTranslationStatus.skippedSameLanguage => '原文就是目标语种，无需翻译',
      };

  static String _translationStatusLabel(SubtitleTranslationStatus status) =>
      switch (status) {
        SubtitleTranslationStatus.awaitingFinal => '识别中',
        SubtitleTranslationStatus.awaitingQueue => '待排队',
        SubtitleTranslationStatus.queued => '已排队',
        SubtitleTranslationStatus.translating => '翻译中',
        SubtitleTranslationStatus.translated => '已完成',
        SubtitleTranslationStatus.failed => '翻译失败',
        SubtitleTranslationStatus.cancelled => '已取消',
        SubtitleTranslationStatus.skippedEmpty => '空字幕',
        SubtitleTranslationStatus.skippedDisabled => '未翻译',
        SubtitleTranslationStatus.skippedUnsupportedLanguage => '语种未识别，原文保留',
        SubtitleTranslationStatus.skippedSameLanguage => '无需翻译',
      };

  static String _friendlyTranslationError(String code) => switch (code) {
    'provider_route_changed' => 'Provider 配置已变化',
    'ambiguous_translation_provider' => '翻译配置冲突',
    'no_remote_provider' => '没有已选远程 Provider',
    'translation_route_unavailable' => '该语向暂无可用翻译服务',
    'unsupported_language_pair' => '不支持此语言方向',
    'cancelled' => '请求已取消',
    'translation_in_progress' => '已有翻译请求进行中',
    _ => code,
  };

  static String _formatTimeline(int milliseconds) {
    final seconds = milliseconds ~/ 1000;
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    final remainingSeconds = seconds % 60;
    final tenths = (milliseconds % 1000) ~/ 100;
    final minuteText = minutes.toString().padLeft(2, '0');
    final secondText = remainingSeconds.toString().padLeft(2, '0');
    final time = '$minuteText:$secondText.$tenths';
    return hours > 0 ? '${hours.toString().padLeft(2, '0')}:$time' : time;
  }
}

enum _CompactSubtitleSettingAction {
  bilingual,
  sourceOnly,
  translatedOnly,
  fontCompact,
  fontStandard,
  fontLarge,
  colorIce,
  colorAmber,
  colorMint,
  colorRose,
  toggleHighContrast,
  opacityLight,
  opacityBalanced,
  opacityClear,
}

final class _CompactSubtitleSegment extends StatelessWidget {
  const _CompactSubtitleSegment({
    required this.segment,
    required this.mode,
    required this.fontScale,
    required this.colorPreset,
    required this.highContrast,
    required this.retryEnabled,
    required this.onRetry,
  });

  final SubtitleSegment segment;
  final SubtitleDisplayMode mode;
  final SubtitleFontScale fontScale;
  final SubtitleColorPreset colorPreset;
  final bool highContrast;
  final bool retryEnabled;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final transcript = segment.transcript;
    final canRetry =
        segment.translationStatus == SubtitleTranslationStatus.failed ||
        segment.translationStatus == SubtitleTranslationStatus.cancelled;
    final fontSize = fontScale.fontSize;
    final sourceColor = highContrast ? Colors.white : colors.onSurface;
    final targetColor = Color(
      highContrast ? colorPreset.darkAccentArgb : colorPreset.lightAccentArgb,
    );
    final secondaryColor = highContrast
        ? const Color(0xFFCFD8E3)
        : colors.onSurfaceVariant;
    final statusColor = canRetry
        ? (highContrast ? const Color(0xFFFFD166) : colors.error)
        : secondaryColor;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 5, 24, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (mode != SubtitleDisplayMode.translatedOnly) ...[
            SubtitleTranscriptLanguageBadge(
              languageCode: transcript.languageCode,
            ),
            const SizedBox(height: 2),
          ],
          if (mode != SubtitleDisplayMode.translatedOnly)
            Text(
              formatSubtitleTextForDisplay(
                transcript.text,
                languageCode: transcript.languageCode,
              ),
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontSize: fontSize,
                height: 1.28,
                color: transcript.isFinal ? sourceColor : secondaryColor,
                fontWeight: transcript.isFinal
                    ? FontWeight.w700
                    : FontWeight.w400,
              ),
            ),
          if (mode == SubtitleDisplayMode.bilingual) const SizedBox(height: 3),
          if (mode != SubtitleDisplayMode.sourceOnly)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        segment.translatedText ??
                            _translationText(segment.translationStatus),
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontSize: fontSize - 1,
                          height: 1.3,
                          color: segment.translatedText == null
                              ? statusColor
                              : targetColor,
                          fontWeight: segment.translatedText == null
                              ? FontWeight.w500
                              : FontWeight.w600,
                        ),
                      ),
                      if (mode == SubtitleDisplayMode.translatedOnly &&
                          canRetry) ...[
                        const SizedBox(height: 2),
                        Text(
                          '原文备份：${transcript.text}',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: secondaryColor),
                        ),
                      ],
                    ],
                  ),
                ),
                if (canRetry)
                  TextButton.icon(
                    onPressed: retryEnabled ? onRetry : null,
                    style: highContrast
                        ? TextButton.styleFrom(
                            foregroundColor: const Color(0xFF64D7FF),
                          )
                        : null,
                    icon: const Icon(Icons.refresh_rounded, size: 16),
                    label: const Text('重试翻译'),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  static String _translationText(SubtitleTranslationStatus status) =>
      switch (status) {
        SubtitleTranslationStatus.awaitingFinal => '识别中…',
        SubtitleTranslationStatus.awaitingQueue => '等待翻译',
        SubtitleTranslationStatus.queued => '翻译排队中',
        SubtitleTranslationStatus.translating => '翻译中…',
        SubtitleTranslationStatus.translated => '译文为空',
        SubtitleTranslationStatus.failed => '翻译失败，原文已保留',
        SubtitleTranslationStatus.cancelled => '翻译已取消',
        SubtitleTranslationStatus.skippedEmpty => '空白字幕',
        SubtitleTranslationStatus.skippedDisabled => '翻译未开启',
        SubtitleTranslationStatus.skippedUnsupportedLanguage => '语种未识别，原文保留',
        SubtitleTranslationStatus.skippedSameLanguage => '原文就是目标语种',
      };
}

final class _DisabledSubtitleTranslationExecutor
    implements SubtitleTranslationExecutor {
  const _DisabledSubtitleTranslationExecutor();

  @override
  Future<String> translate(SubtitleTranslationRequest request) async =>
      throw StateError('Translation is disabled for this session.');

  @override
  Future<void> cancel(String requestId) async {}
}
