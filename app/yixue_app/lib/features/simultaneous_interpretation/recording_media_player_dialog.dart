import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:yixue_app/core/windows_associated_file_opener.dart';

abstract class RecordingPlaybackController extends ChangeNotifier {
  bool get isVideo;
  double get videoAspectRatio => 16 / 9;
  bool get isLoading;
  bool get isPlaying;
  Duration get position;
  Duration get duration;
  String? get failureMessage;
  String? get failureDetails;

  Widget buildVideoView();
  Future<void> open(File file);
  Future<void> togglePlayback();
  Future<void> seek(Duration value);
  Future<void> close();
}

typedef RecordingPlaybackControllerFactory =
    RecordingPlaybackController Function(bool isVideo);
typedef RecordingPlaybackFileTypeResolver =
    Future<FileSystemEntityType> Function(String path);
typedef RecordingPlaybackPlayerFactory = Player Function();

/// Requests that the operating system open a locally saved recording.
///
/// This confirms only that the open request was accepted, not that the
/// associated player rendered or played the file.
Future<void> launchRecordingWithSystemPlayer(File file) async {
  if (!await file.exists()) {
    throw FileSystemException('录制文件已不存在。', file.path);
  }
  final path = file.absolute.path;
  if (Platform.isWindows) {
    openWindowsAssociatedFile(path);
  } else if (Platform.isMacOS) {
    await Process.start('open', <String>[
      path,
    ], mode: ProcessStartMode.detached);
  } else if (Platform.isLinux) {
    await Process.start('xdg-open', <String>[
      path,
    ], mode: ProcessStartMode.detached);
  } else {
    throw UnsupportedError('当前系统没有配置默认媒体播放器。');
  }
}

enum RecordingPlaybackTimeoutStage {
  playerOpen,
  firstVideoFrame,
  audioPlayback,
}

final class RecordingPlaybackTimeout implements Exception {
  const RecordingPlaybackTimeout({required this.stage, required this.cause});

  final RecordingPlaybackTimeoutStage stage;
  final TimeoutException cause;

  @override
  String toString() => 'RecordingPlaybackTimeout(${stage.name}): $cause';
}

/// Confirms playback from two consecutive, strictly increasing position
/// samples. A single non-zero timestamp can be an initial seek or stale value.
final class RecordingPlaybackProgressTracker {
  Duration _lastPosition = Duration.zero;
  var _consecutiveAdvances = 0;

  bool observe(Duration position) {
    if (position > _lastPosition && position > Duration.zero) {
      if (_consecutiveAdvances < 2) _consecutiveAdvances++;
    } else {
      _consecutiveAdvances = 0;
    }
    _lastPosition = position;
    return _consecutiveAdvances >= 2;
  }
}

/// Waits for the player to open, initialize its video output, and advance its
/// playback position. MediaKit's first-frame signal can be emitted when the
/// texture is only initialized, so it is not sufficient by itself to dismiss
/// the loading state. This avoids a native screenshot, which could hold
/// libmpv's lock and prevent the history player from ever closing.
Future<void> waitForRecordingVideoReady({
  required Future<void> playerOpen,
  required Future<void> firstFrameRendered,
  required Future<void> videoPlaybackProgress,
  required Future<void> playerFailure,
  required Future<void> stopRequested,
  required bool Function() shouldStop,
  required Duration openTimeout,
  required Duration firstFrameTimeout,
}) async {
  try {
    await Future.any<void>([playerOpen, stopRequested]).timeout(openTimeout);
  } on TimeoutException catch (error) {
    throw RecordingPlaybackTimeout(
      stage: RecordingPlaybackTimeoutStage.playerOpen,
      cause: error,
    );
  }
  if (shouldStop()) return;

  try {
    await Future.any<void>([
      Future.wait<void>([firstFrameRendered, videoPlaybackProgress])
          .then<void>((_) {}),
      playerFailure.then<void>((_) {
        throw const FormatException('播放器报告了媒体解码错误。');
      }),
      stopRequested,
    ]).timeout(firstFrameTimeout);
  } on TimeoutException catch (error) {
    throw RecordingPlaybackTimeout(
      stage: RecordingPlaybackTimeoutStage.firstVideoFrame,
      cause: error,
    );
  }
}

/// A successful open without a decoded audio duration can leave an empty WAV
/// looking playable. Wait for a non-zero track duration and advancing playback.
Future<void> waitForRecordingAudioReady({
  required Future<void> playerOpen,
  required Future<void> audioDurationAvailable,
  required Future<void> audioPlaybackProgress,
  required Future<void> playerFailure,
  required Future<void> stopRequested,
  required bool Function() shouldStop,
  required Duration openTimeout,
  required Duration durationTimeout,
}) async {
  try {
    await Future.any<void>([playerOpen, stopRequested]).timeout(openTimeout);
  } on TimeoutException catch (error) {
    throw RecordingPlaybackTimeout(
      stage: RecordingPlaybackTimeoutStage.playerOpen,
      cause: error,
    );
  }
  if (shouldStop()) return;

  try {
    await Future.any<void>([
      Future.wait<void>([audioDurationAvailable, audioPlaybackProgress])
          .then<void>((_) {}),
      playerFailure.then<void>((_) {
        throw const FormatException('播放器报告了音频解码错误。');
      }),
      stopRequested,
    ]).timeout(durationTimeout);
  } on TimeoutException catch (error) {
    throw RecordingPlaybackTimeout(
      stage: RecordingPlaybackTimeoutStage.audioPlayback,
      cause: error,
    );
  }
}

/// A lazy, in-app player for validated local WAV and MP4 files.
///
/// Callers are responsible for revalidating the file against the recording
/// index immediately before showing this dialog. Native media libraries are
/// initialized only when a user explicitly opens a recording.
final class RecordingMediaPlayerDialog extends StatefulWidget {
  const RecordingMediaPlayerDialog({
    required this.file,
    required this.title,
    this.details,
    this.preferExternalPlayer = false,
    this.controllerFactory,
    this.externalPlayerLauncher,
    this.onDialogDisposed,
    this.onSystemPlayerHandoffRequested,
    @visibleForTesting this.fileTypeResolver,
    @visibleForTesting this.mediaKitInitializer,
    @visibleForTesting this.playerFactory,
    super.key,
  });

  final File file;
  final String title;
  final String? details;
  final bool preferExternalPlayer;
  final RecordingPlaybackControllerFactory? controllerFactory;
  final Future<void> Function(File file)? externalPlayerLauncher;

  /// Notifies the history owner to close this route and release its media
  /// lease before launching the associated system player.
  final VoidCallback? onSystemPlayerHandoffRequested;

  /// Reports the native teardown future while the dialog is being disposed.
  /// A null value means the dialog owns no remaining in-app player resources.
  @visibleForTesting
  final ValueChanged<Future<void>?>? onDialogDisposed;
  @visibleForTesting
  final RecordingPlaybackFileTypeResolver? fileTypeResolver;
  @visibleForTesting
  final VoidCallback? mediaKitInitializer;
  @visibleForTesting
  final RecordingPlaybackPlayerFactory? playerFactory;

  @override
  State<RecordingMediaPlayerDialog> createState() =>
      _RecordingMediaPlayerDialogState();
}

final class _RecordingMediaPlayerDialogState
    extends State<RecordingMediaPlayerDialog> {
  static const _controllerCloseTimeout = Duration(seconds: 6);

  RecordingPlaybackController? _controller;
  Future<void>? _pendingControllerClose;
  double? _seekDraftMilliseconds;
  var _openingExternalPlayer = false;
  var _controllerCloseTimedOut = false;
  String? _externalPlayerError;
  var _externalPlayerRequestSucceeded = false;
  String? _previousMediaFailure;
  String? _previousMediaFailureDetails;

  @override
  void initState() {
    super.initState();
    if (widget.preferExternalPlayer) {
      // Windows file associations can launch a player without confirming
      // that it rendered video or played audio. Let the user choose explicitly.
      return;
    }
    _controller = _createController(_isVideo);
    unawaited(_controller!.open(widget.file));
  }

  @override
  void dispose() {
    final controller = _controller;
    _controller = null;
    Future<void>? pendingClose = _pendingControllerClose;
    if (controller != null) {
      pendingClose = _startControllerClose(controller);
      unawaited(
        pendingClose.catchError((Object error, StackTrace stackTrace) {
          FlutterError.reportError(
            FlutterErrorDetails(
              exception: error,
              stack: stackTrace,
              library: '译学媒体播放器',
              context: ErrorDescription('关闭录音或视频播放器时发生错误'),
            ),
          );
        }),
      );
    }
    widget.onDialogDisposed?.call(pendingClose);
    super.dispose();
  }

  Future<void> _closeAndDisposeController(
    RecordingPlaybackController controller,
  ) async {
    final closeAndDispose = _startControllerClose(controller);
    try {
      await closeAndDispose.timeout(_controllerCloseTimeout);
    } on TimeoutException {
      // Future.timeout does not cancel the native close. Keep both the
      // controller and its native resources alive until that original future
      // settles, and prevent another in-app player from opening meanwhile.
      if (mounted) {
        setState(() {
          _controllerCloseTimedOut = true;
          _externalPlayerError = '播放器仍在释放资源，请稍后重试。';
        });
      }
    }
  }

  Future<void> _startControllerClose(RecordingPlaybackController controller) {
    final existingClose = _pendingControllerClose;
    if (existingClose != null) return existingClose;
    final closeAndDispose = Future<void>.sync(controller.close).then<void>(
      (_) => controller.dispose(),
      onError: (Object error, StackTrace stackTrace) {
        controller.dispose();
        Error.throwWithStackTrace(error, stackTrace);
      },
    );
    _pendingControllerClose = closeAndDispose;
    unawaited(
      closeAndDispose.then<void>(
        (_) => _onControllerCloseSettled(closeAndDispose),
        onError: (Object error, StackTrace stackTrace) {
          _onControllerCloseSettled(closeAndDispose);
        },
      ),
    );
    return closeAndDispose;
  }

  void _onControllerCloseSettled(Future<void> closeAndDispose) {
    if (!identical(_pendingControllerClose, closeAndDispose)) return;
    _pendingControllerClose = null;
    if (!mounted) return;
    setState(() {
      if (_controllerCloseTimedOut) _externalPlayerError = null;
      _controllerCloseTimedOut = false;
    });
  }

  bool get _isVideo => widget.file.path.toLowerCase().endsWith('.mp4');

  RecordingPlaybackController _createController(bool isVideo) =>
      widget.controllerFactory?.call(isVideo) ??
      _MediaKitRecordingPlaybackController(
        isVideo: isVideo,
        fileTypeResolver:
            widget.fileTypeResolver ??
            (path) => FileSystemEntity.type(path, followLinks: false),
        mediaKitInitializer:
            widget.mediaKitInitializer ?? MediaKit.ensureInitialized,
        playerFactory: widget.playerFactory ?? (() => Player()),
      );

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.sizeOf(context);
    final dialogWidth = math
        .min(960.0, math.max(1.0, screenSize.width - 32))
        .toDouble();
    final dialogHeight = (screenSize.height * 0.82)
        .clamp(120.0, 720.0)
        .toDouble();
    final controller = _controller;
    final detailsText = widget.details;

    return Dialog(
      constraints: BoxConstraints(
        minWidth: math.min(280.0, dialogWidth),
        maxWidth: dialogWidth,
      ),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: dialogWidth,
          maxHeight: dialogHeight,
        ),
        child: SizedBox(
          width: dialogWidth,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: SingleChildScrollView(
              child: controller == null
                  ? _buildContent(context, detailsText, null)
                  : AnimatedBuilder(
                      animation: controller,
                      builder: (context, _) =>
                          _buildContent(context, detailsText, controller),
                    ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildContent(
    BuildContext context,
    String? detailsText,
    RecordingPlaybackController? controller,
  ) {
    final colors = Theme.of(context).colorScheme;
    final videoAspectRatio = _safeVideoAspectRatio(
      controller?.videoAspectRatio ?? 16 / 9,
    );
    final maxVideoHeight = math.min(
      480.0,
      math.max(120.0, MediaQuery.sizeOf(context).height * 0.45),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildHeader(context),
        if (detailsText != null && detailsText.trim().isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            detailsText,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: colors.onSurfaceVariant),
          ),
        ],
        const SizedBox(height: 16),
        if (controller == null)
          _buildSystemPlayerSurface(context)
        else if (controller.failureMessage case final failure?)
          _buildFailure(context, controller, failure)
        else if (controller.isVideo)
          LayoutBuilder(
            builder: (context, constraints) {
              final maxWidth = constraints.maxWidth.isFinite
                  ? constraints.maxWidth
                  : 920.0;
              final width = math.min(
                maxWidth,
                maxVideoHeight * videoAspectRatio,
              );
              final height = width / videoAspectRatio;
              return Center(
                child: SizedBox(
                  key: const ValueKey('recording-video-viewport'),
                  width: width,
                  height: height,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        controller.buildVideoView(),
                        if (controller.isLoading)
                          const ColoredBox(
                            color: Colors.black54,
                            child: _LoadingMedia(message: '正在等待视频画面…'),
                          ),
                      ],
                    ),
                  ),
                ),
              );
            },
          )
        else
          _buildAudioSurface(context, controller),
        const SizedBox(height: 12),
        _buildControls(context),
      ],
    );
  }

  double _safeVideoAspectRatio(double ratio) =>
      ratio.isFinite && ratio >= 0.1 && ratio <= 10 ? ratio : 16 / 9;

  Widget _buildSystemPlayerSurface(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      constraints: const BoxConstraints(minHeight: 88),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                _externalPlayerError == null
                    ? Icons.play_circle_outline_rounded
                    : Icons.error_outline_rounded,
                size: 28,
                color: _externalPlayerError == null
                    ? colors.primary
                    : colors.error,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _externalPlayerError != null
                          ? '系统播放器未能打开文件'
                          : _externalPlayerRequestSucceeded
                          ? '已请求打开系统播放器'
                          : '选择播放方式',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      _externalPlayerError ??
                          (_externalPlayerRequestSucceeded
                              ? 'Windows 已接受打开请求；若播放器没有画面或声音，请改用译学内播放。'
                              : '可直接用译学内播放，也可交给 Windows 默认播放器。'),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: _externalPlayerError == null
                            ? colors.onSurfaceVariant
                            : colors.error,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (_previousMediaFailure case final failure?) ...[
            const SizedBox(height: 6),
            Text(
              '译学内播放提示：$failure',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: colors.error),
            ),
            if (_previousMediaFailureDetails case final details?)
              Tooltip(
                message: details,
                child: const Align(
                  alignment: Alignment.centerRight,
                  child: Icon(Icons.info_outline_rounded, size: 18),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(
          _isVideo ? Icons.video_file_outlined : Icons.audio_file_outlined,
          color: colors.primary,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            widget.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
        IconButton(
          tooltip: '关闭播放器',
          onPressed: () => Navigator.of(context).maybePop(),
          icon: const Icon(Icons.close_rounded),
        ),
      ],
    );
  }

  Widget _buildAudioSurface(
    BuildContext context,
    RecordingPlaybackController controller,
  ) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      constraints: const BoxConstraints(minHeight: 180),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: controller.isLoading
          ? const _LoadingMedia(message: '正在准备 WAV 播放器…')
          : Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.graphic_eq_rounded,
                  size: 56,
                  color: colors.primary,
                  semanticLabel: '录音',
                ),
                const SizedBox(height: 12),
                Text('本机录音', style: Theme.of(context).textTheme.titleMedium),
              ],
            ),
    );
  }

  Widget _buildFailure(
    BuildContext context,
    RecordingPlaybackController controller,
    String message,
  ) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      constraints: const BoxConstraints(minHeight: 180),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: colors.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.error_outline_rounded, color: colors.error),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  message,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: colors.onErrorContainer,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '历史文件没有被修改。视频可能未完成录制，或当前播放器无法识别其中的编码；录音则可能没有写入有效音频帧。',
            style: Theme.of(context).textTheme.bodyMedium
                ?.copyWith(color: colors.onErrorContainer),
          ),
          if (controller.failureDetails case final details?) ...[
            const SizedBox(height: 8),
            SelectableText(
              details,
              maxLines: 4,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: colors.onErrorContainer),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _openWithSystemPlayer() async {
    if (_openingExternalPlayer) return;
    setState(() {
      _openingExternalPlayer = true;
      _externalPlayerError = null;
      _externalPlayerRequestSucceeded = false;
    });
    try {
      final pendingClose = _pendingControllerClose;
      if (pendingClose != null) {
        try {
          await pendingClose.timeout(_controllerCloseTimeout);
        } on TimeoutException {
          if (mounted) {
            setState(() {
              _controllerCloseTimedOut = true;
              _externalPlayerError = '播放器仍在释放资源，请稍后重试。';
            });
          }
          return;
        }
      }
      final controller = _controller;
      if (controller != null) {
        setState(() {
          _previousMediaFailure = controller.failureMessage;
          _previousMediaFailureDetails = controller.failureDetails;
          _controller = null;
        });
        await _closeAndDisposeController(controller);
        if (_controllerCloseTimedOut) return;
      }
      if (!mounted) return;
      final handoff = widget.onSystemPlayerHandoffRequested;
      if (handoff != null) {
        handoff();
        Navigator.of(context).pop();
        return;
      }
      final launcher =
          widget.externalPlayerLauncher ?? launchRecordingWithSystemPlayer;
      await launcher(widget.file);
      if (mounted) setState(() => _externalPlayerRequestSucceeded = true);
    } on Object catch (error) {
      if (mounted) {
        setState(() => _externalPlayerError = '打开系统播放器失败：$error');
      }
    } finally {
      if (mounted) setState(() => _openingExternalPlayer = false);
    }
  }

  void _startInAppPlayback() {
    if (_controller != null || _pendingControllerClose != null || !mounted) {
      return;
    }
    final controller = _createController(_isVideo);
    setState(() {
      _controller = controller;
      _externalPlayerError = null;
      _externalPlayerRequestSucceeded = false;
      _previousMediaFailure = null;
      _previousMediaFailureDetails = null;
    });
    unawaited(controller.open(widget.file));
  }

  Widget _buildControls(BuildContext context) {
    final controller = _controller;
    if (controller == null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OutlinedButton.icon(
            key: const ValueKey('open-recording-in-app-player'),
            onPressed: _pendingControllerClose == null
                ? _startInAppPlayback
                : null,
            icon: Icon(
              _pendingControllerClose == null
                  ? Icons.play_circle_outline_rounded
                  : Icons.hourglass_top_rounded,
            ),
            label: Text(
              _pendingControllerClose == null ? '译学内播放' : '正在释放播放器资源…',
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            key: const ValueKey('open-recording-in-system-player'),
            onPressed: _openingExternalPlayer ? null : _openWithSystemPlayer,
            icon: _openingExternalPlayer
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.open_in_new_rounded),
            label: Text(
              _openingExternalPlayer
                  ? '正在请求系统播放器…'
                  : _externalPlayerRequestSucceeded
                  ? '再次用系统播放器打开'
                  : '用系统播放器打开',
            ),
          ),
        ],
      );
    }
    final canControl =
        !controller.isLoading && controller.failureMessage == null;
    final duration = controller.duration;
    final canSeek = canControl && duration > Duration.zero;
    final maxMilliseconds = duration.inMilliseconds <= 0
        ? 1
        : duration.inMilliseconds;
    final positionMs =
        (_seekDraftMilliseconds ??
                controller.position.inMilliseconds.toDouble())
            .clamp(0, maxMilliseconds.toDouble())
            .toDouble();
    final transportButtons = <Widget>[
      IconButton(
        tooltip: '向后 10 秒',
        onPressed: canSeek
            ? () => _seekRelative(const Duration(seconds: -10))
            : null,
        icon: const Icon(Icons.replay_10_rounded),
      ),
      IconButton.filled(
        tooltip: controller.isPlaying ? '暂停' : '播放',
        onPressed: canControl
            ? () => unawaited(controller.togglePlayback())
            : null,
        icon: Icon(
          controller.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
        ),
      ),
      IconButton(
        tooltip: '向前 10 秒',
        onPressed: canSeek
            ? () => _seekRelative(const Duration(seconds: 10))
            : null,
        icon: const Icon(Icons.forward_10_rounded),
      ),
    ];
    final positionLabel = Text(
      '${_formatDuration(controller.position)} / ${_formatDuration(duration)}',
      style: Theme.of(context).textTheme.bodyMedium,
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth < 360) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: transportButtons,
                  ),
                  Align(alignment: Alignment.centerRight, child: positionLabel),
                ],
              );
            }
            return Row(
              children: [...transportButtons, const Spacer(), positionLabel],
            );
          },
        ),
        Slider(
          min: 0,
          max: maxMilliseconds.toDouble(),
          value: positionMs,
          onChanged: canSeek
              ? (value) => setState(() => _seekDraftMilliseconds = value)
              : null,
          onChangeEnd: canSeek
              ? (value) {
                  setState(() => _seekDraftMilliseconds = null);
                  unawaited(
                    controller.seek(Duration(milliseconds: value.round())),
                  );
                }
              : null,
          semanticFormatterCallback: (value) =>
              _formatDuration(Duration(milliseconds: value.round())),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: OutlinedButton.icon(
            key: const ValueKey('open-recording-in-system-player'),
            onPressed: _openingExternalPlayer ? null : _openWithSystemPlayer,
            icon: _openingExternalPlayer
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.open_in_new_rounded),
            label: Text(_openingExternalPlayer ? '正在请求系统播放器…' : '用系统播放器打开'),
          ),
        ),
        if (_externalPlayerError case final error?)
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              error,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
      ],
    );
  }

  Future<void> _seekRelative(Duration delta) async {
    final controller = _controller;
    if (controller == null) return;
    final target = controller.position + delta;
    final upperBound = controller.duration;
    await controller.seek(
      target < Duration.zero
          ? Duration.zero
          : target > upperBound
          ? upperBound
          : target,
    );
  }

  String _formatDuration(Duration value) {
    final hours = value.inHours;
    final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (hours > 0) return '$hours:$minutes:$seconds';
    return '$minutes:$seconds';
  }
}

final class _LoadingMedia extends StatelessWidget {
  const _LoadingMedia({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 14),
          Text(message, textAlign: TextAlign.center),
        ],
      ),
    ),
  );
}

final class _MediaKitRecordingPlaybackController
    extends RecordingPlaybackController {
  _MediaKitRecordingPlaybackController({
    required this.isVideo,
    required this.fileTypeResolver,
    required this.mediaKitInitializer,
    required this.playerFactory,
  });

  static bool _mediaKitInitialized = false;
  static const _openTimeout = Duration(seconds: 15);
  static const _firstFrameTimeout = Duration(seconds: 12);
  static const _audioDurationTimeout = Duration(seconds: 8);

  @override
  final bool isVideo;
  final RecordingPlaybackFileTypeResolver fileTypeResolver;
  final VoidCallback mediaKitInitializer;
  final RecordingPlaybackPlayerFactory playerFactory;

  Player? _player;
  VideoController? _videoController;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  final Completer<void> _firstFailure = Completer<void>();
  final Completer<void> _stopRequested = Completer<void>();
  final Completer<void> _videoPlaybackProgress = Completer<void>();
  final Completer<void> _audioDurationAvailable = Completer<void>();
  final Completer<void> _audioPlaybackProgress = Completer<void>();
  final RecordingPlaybackProgressTracker _playbackPositionProgress =
      RecordingPlaybackProgressTracker();
  Future<void>? _closeFuture;
  Future<void>? _mediaReadinessFuture;
  var _isLoading = true;
  var _isPlaying = false;
  var _position = Duration.zero;
  var _duration = Duration.zero;
  var _closed = false;
  String? _failureMessage;
  String? _failureDetails;

  @override
  bool get isLoading => _isLoading;

  @override
  double get videoAspectRatio {
    final params = _player?.state.videoParams;
    if (params == null) return 16 / 9;
    final aspect = params.aspect;
    if (aspect != null && aspect.isFinite && aspect > 0) return aspect;
    final width = params.dw ?? params.w;
    final height = params.dh ?? params.h;
    if (width != null && height != null && width > 0 && height > 0) {
      return width / height;
    }
    return 16 / 9;
  }

  @override
  bool get isPlaying => _isPlaying;

  @override
  Duration get position => _position;

  @override
  Duration get duration => _duration;

  @override
  String? get failureMessage => _failureMessage;

  @override
  String? get failureDetails => _failureDetails;

  @override
  Widget buildVideoView() {
    final controller = _videoController;
    if (controller == null) return const ColoredBox(color: Colors.black);
    return Video(
      controller: controller,
      controls: NoVideoControls,
      wakelock: false,
      pauseUponEnteringBackgroundMode: true,
      resumeUponEnteringForegroundMode: false,
    );
  }

  @override
  Future<void> open(File file) async {
    try {
      final fileType = await fileTypeResolver(file.path);
      // The dialog can be dismissed while the asynchronous file check is in
      // flight. `close()` cannot dispose a Player that does not exist yet, so
      // stop here before initializing MediaKit or allocating native resources.
      if (_closed) return;
      if (fileType != FileSystemEntityType.file) {
        throw FileSystemException('录制文件不存在或不再是普通文件。', file.path);
      }
      if (!_mediaKitInitialized) {
        mediaKitInitializer();
        _mediaKitInitialized = true;
      }
      final player = playerFactory();
      _player = player;
      if (isVideo) _videoController = VideoController(player);
      _listenToPlayer(player);
      _isLoading = true;
      _notifyIfOpen();

      final playerOpen = player.open(
        Media(file.absolute.uri.toString()),
        play: true,
      );
      if (isVideo) {
        final controller = _videoController;
        if (controller == null) {
          _setFailure(
            '译学没有创建视频画面。请关闭播放器后重试。',
            'VideoController was not initialized.',
          );
          await close();
          return;
        }
        final mediaReadiness = waitForRecordingVideoReady(
          playerOpen: playerOpen,
          firstFrameRendered: controller.waitUntilFirstFrameRendered,
          videoPlaybackProgress: _videoPlaybackProgress.future,
          playerFailure: _firstFailure.future,
          stopRequested: _stopRequested.future,
          shouldStop: () => _closed,
          openTimeout: _openTimeout,
          firstFrameTimeout: _firstFrameTimeout,
        );
        _mediaReadinessFuture = mediaReadiness;
        await mediaReadiness;
      } else {
        final mediaReadiness = waitForRecordingAudioReady(
          playerOpen: playerOpen,
          audioDurationAvailable: _audioDurationAvailable.future,
          audioPlaybackProgress: _audioPlaybackProgress.future,
          playerFailure: _firstFailure.future,
          stopRequested: _stopRequested.future,
          shouldStop: () => _closed,
          openTimeout: _openTimeout,
          durationTimeout: _audioDurationTimeout,
        );
        _mediaReadinessFuture = mediaReadiness;
        await mediaReadiness;
      }
      if (_closed) return;
      if (_failureMessage != null) {
        await close();
        return;
      }
      // Player.open can finish before video output is ready. Keep the loading
      // state until output initialization and playback progress are observed.
      _isLoading = false;
      _notifyIfOpen();
    } on RecordingPlaybackTimeout catch (error) {
      if (!_closed) {
        final message = switch (error.stage) {
          RecordingPlaybackTimeoutStage.firstVideoFrame => '视频未能开始输出画面。',
          RecordingPlaybackTimeoutStage.audioPlayback =>
            '录音未能开始播放，或没有可播放的音频数据。',
          RecordingPlaybackTimeoutStage.playerOpen =>
            isVideo ? '视频打开超时。' : '录音打开超时。',
        };
        _setFailure(message, error.toString());
      }
      await close();
    } on TimeoutException catch (error) {
      if (!_closed) {
        _setFailure(isVideo ? '视频播放准备超时。' : '录音打开超时。', error.toString());
      }
      await close();
    } on Object catch (error) {
      if (!_closed) {
        _setFailure(
          isVideo ? '视频无法播放。' : '录音无法播放。',
          _limitDetails(error.toString()),
        );
      }
      await close();
    }
  }

  void _listenToPlayer(Player player) {
    _subscriptions.add(
      player.stream.position.listen((value) {
        if (_playbackPositionProgress.observe(value)) {
          if (isVideo && !_videoPlaybackProgress.isCompleted) {
            _videoPlaybackProgress.complete();
          } else if (!isVideo && !_audioPlaybackProgress.isCompleted) {
            _audioPlaybackProgress.complete();
          }
        }
        _position = value;
        _notifyIfOpen();
      }),
    );
    _subscriptions.add(
      player.stream.duration.listen((value) {
        _duration = value;
        if (!isVideo &&
            value > Duration.zero &&
            !_audioDurationAvailable.isCompleted) {
          _audioDurationAvailable.complete();
        }
        _notifyIfOpen();
      }),
    );
    _subscriptions.add(
      player.stream.playing.listen((value) {
        _isPlaying = value;
        _notifyIfOpen();
      }),
    );
    _subscriptions.add(
      player.stream.error.listen((value) {
        if (value.trim().isEmpty || _closed) return;
        _setFailure(isVideo ? '视频解码失败。' : '录音解码失败。', _limitDetails(value));
        unawaited(close());
        if (!_firstFailure.isCompleted) _firstFailure.complete();
      }),
    );
  }

  @override
  Future<void> togglePlayback() async {
    final player = _player;
    if (player == null || _closed) return;
    try {
      await player.playOrPause();
    } on Object catch (error) {
      _setFailure('播放控制失败。', _limitDetails(error.toString()));
    }
  }

  @override
  Future<void> seek(Duration value) async {
    final player = _player;
    if (player == null || _closed) return;
    try {
      await player.seek(value);
    } on Object catch (error) {
      _setFailure('无法跳转到所选时间。', _limitDetails(error.toString()));
    }
  }

  @override
  Future<void> close() async {
    final activeClose = _closeFuture;
    if (activeClose != null) return activeClose;
    if (_closed) return;
    _closed = true;
    if (!_stopRequested.isCompleted) _stopRequested.complete();
    final closeFuture = _closePlayerResources();
    _closeFuture = closeFuture;
    await closeFuture;
  }

  Future<void> _closePlayerResources() async {
    for (final subscription in _subscriptions) {
      try {
        await subscription.cancel();
      } on Object {
        // Continue tearing down the decoder if a stream subscription failed.
      }
    }
    _subscriptions.clear();
    final mediaReadiness = _mediaReadinessFuture;
    if (mediaReadiness != null) {
      try {
        // The readiness waiter is interrupted by stopRequested; it does not
        // run a native screenshot that could hold libmpv's dispose lock.
        await mediaReadiness;
      } on Object {
        // A decoder error/timeout is already reflected in the UI state.
      }
    }
    final player = _player;
    _player = null;
    _videoController = null;
    if (player != null) {
      try {
        // A timed-out Player.open does not cancel its native operation. Always
        // dispose the player so a late native open cannot keep the decoder and
        // file handle alive after the dialog has reported failure. Keep this
        // future alive until native disposal actually settles; a timeout here
        // would release the history page's media lease too early.
        await player.dispose();
      } on Object {
        // The native dispose future has settled with an error; allow the
        // history lease to release instead of leaving a permanent lock.
      }
    }
  }

  void _setFailure(String message, String details) {
    if (_closed || _failureMessage != null) return;
    _failureMessage = message;
    _failureDetails = _limitDetails(details);
    _isLoading = false;
    _notifyIfOpen();
  }

  void _notifyIfOpen() {
    if (!_closed) notifyListeners();
  }

  String _limitDetails(String value) =>
      value.length <= 360 ? value : '${value.substring(0, 360)}…';
}
