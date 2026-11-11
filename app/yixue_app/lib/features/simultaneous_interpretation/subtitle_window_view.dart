import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'asr_language_registry.dart';
import 'subtitle_display_preferences.dart';
import 'subtitle_session_contract.dart';
import 'subtitle_text_presentation.dart';

enum SubtitleWindowControlAction {
  displayBilingual,
  displaySourceOnly,
  displayTranslatedOnly,
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
  switchDirection,
  toggleAudioRecording,
  toggleScreenRecording,
}

/// One display-ready caption copied from the owning interpretation session.
/// The subtitle process only presents text; it never owns capture or history.
final class SubtitleWindowCue {
  const SubtitleWindowCue({
    required this.sourceText,
    this.cueId,
    this.translatedText,
    this.languageCode,
    this.sourceIsFinal = true,
    this.translationStatusLabel,
  });

  final String? cueId;
  final String sourceText;
  final String? translatedText;
  final String? languageCode;
  final bool sourceIsFinal;
  final String? translationStatusLabel;

  Map<String, Object?> toJson() => <String, Object?>{
    'cueId': cueId,
    'sourceText': sourceText,
    'translatedText': translatedText,
    'languageCode': languageCode,
    'sourceIsFinal': sourceIsFinal,
    'translationStatusLabel': translationStatusLabel,
  };

  factory SubtitleWindowCue.fromJson(Map<String, dynamic> json) =>
      SubtitleWindowCue(
        cueId: json['cueId'] as String?,
        sourceText: _stringValue(json['sourceText'], fallback: ''),
        translatedText: json['translatedText'] as String?,
        languageCode: json['languageCode'] as String?,
        sourceIsFinal: json['sourceIsFinal'] is bool
            ? json['sourceIsFinal'] as bool
            : true,
        translationStatusLabel: json['translationStatusLabel'] as String?,
      );
}

/// Immutable JSON snapshot sent from the session owner to the subtitle child.
final class SubtitleWindowSnapshot {
  SubtitleWindowSnapshot({
    required this.sessionId,
    required this.sessionKind,
    required this.sessionStatus,
    required this.sourceKind,
    required this.sourceLabel,
    required this.sourceStatusLabel,
    required this.sourceLanguageLabel,
    required this.targetLanguageLabel,
    Iterable<SubtitleWindowCue> cues = const <SubtitleWindowCue>[],
    this.translationStatusLabel,
    this.displayPreferences = SubtitleDisplayPreferences.defaults,
    this.audioRecordingActive = false,
    this.screenRecordingActive = false,
    this.screenRecordingHasTarget = false,
    this.canChangeDirection = true,
  }) : cues = List<SubtitleWindowCue>.unmodifiable(_latestCues(cues));

  static const int schemaVersion = 2;
  static const int maxCueCount = 12;

  final String sessionId;
  final SubtitleSessionKind sessionKind;
  final SubtitleSessionStatus sessionStatus;
  final SubtitleAudioSourceKind sourceKind;
  final String sourceLabel;
  final String sourceStatusLabel;
  final String sourceLanguageLabel;
  final String targetLanguageLabel;
  final String? translationStatusLabel;
  final SubtitleDisplayPreferences displayPreferences;
  final bool audioRecordingActive;
  final bool screenRecordingActive;
  final bool screenRecordingHasTarget;
  final bool canChangeDirection;
  final List<SubtitleWindowCue> cues;

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': schemaVersion,
    'sessionId': sessionId,
    'sessionKind': sessionKind.name,
    'sessionStatus': sessionStatus.name,
    'sourceKind': sourceKind.name,
    'sourceLabel': sourceLabel,
    'sourceStatusLabel': sourceStatusLabel,
    'sourceLanguageLabel': sourceLanguageLabel,
    'targetLanguageLabel': targetLanguageLabel,
    'translationStatusLabel': translationStatusLabel,
    'displayPreferences': displayPreferences.toJson(),
    'audioRecordingActive': audioRecordingActive,
    'screenRecordingActive': screenRecordingActive,
    'screenRecordingHasTarget': screenRecordingHasTarget,
    'canChangeDirection': canChangeDirection,
    'cues': cues.map((cue) => cue.toJson()).toList(growable: false),
  };

  factory SubtitleWindowSnapshot.fromJson(Map<String, dynamic> json) {
    final version = json['schemaVersion'];
    if (version != 1 && version != schemaVersion) {
      throw FormatException(
        'Unsupported subtitle window snapshot schema: $version',
      );
    }
    final rawPreferences = json['displayPreferences'];
    final rawCues = json['cues'];
    return SubtitleWindowSnapshot(
      sessionId: _stringValue(json['sessionId'], fallback: ''),
      sessionKind: _enumByName(
        SubtitleSessionKind.values,
        json['sessionKind'],
        SubtitleSessionKind.meeting,
      ),
      sessionStatus: _enumByName(
        SubtitleSessionStatus.values,
        json['sessionStatus'],
        SubtitleSessionStatus.idle,
      ),
      sourceKind: _enumByName(
        SubtitleAudioSourceKind.values,
        json['sourceKind'],
        SubtitleAudioSourceKind.systemOutput,
      ),
      sourceLabel: _stringValue(json['sourceLabel'], fallback: ''),
      sourceStatusLabel: _stringValue(
        json['sourceStatusLabel'],
        fallback: '状态未知',
      ),
      sourceLanguageLabel: _stringValue(
        json['sourceLanguageLabel'],
        fallback: '原文',
      ),
      targetLanguageLabel: _stringValue(
        json['targetLanguageLabel'],
        fallback: '译文',
      ),
      translationStatusLabel: json['translationStatusLabel'] as String?,
      displayPreferences: rawPreferences is Map
          ? SubtitleDisplayPreferences.fromJson(
              Map<String, dynamic>.from(rawPreferences),
            )
          : SubtitleDisplayPreferences.defaults,
      audioRecordingActive: json['audioRecordingActive'] == true,
      screenRecordingActive: json['screenRecordingActive'] == true,
      screenRecordingHasTarget: json['screenRecordingHasTarget'] == true,
      canChangeDirection: json['canChangeDirection'] != false,
      cues: rawCues is List
          ? rawCues.whereType<Map>().map(
              (cue) =>
                  SubtitleWindowCue.fromJson(Map<String, dynamic>.from(cue)),
            )
          : const <SubtitleWindowCue>[],
    );
  }

  static Iterable<SubtitleWindowCue> _latestCues(
    Iterable<SubtitleWindowCue> cues,
  ) {
    final values = cues.toList(growable: false);
    if (values.length <= maxCueCount) return values;
    return values.skip(values.length - maxCueCount);
  }
}

/// Compact, resizable overlay showing the newest source and translated cue.
final class SubtitleWindowView extends StatefulWidget {
  const SubtitleWindowView({
    required this.snapshot,
    this.onClose,
    this.onControlAction,
    this.controlMessage,
    super.key,
  });

  final SubtitleWindowSnapshot snapshot;
  final VoidCallback? onClose;
  final ValueChanged<SubtitleWindowControlAction>? onControlAction;
  final String? controlMessage;

  @override
  State<SubtitleWindowView> createState() => _SubtitleWindowViewState();
}

final class _SubtitleWindowViewState extends State<SubtitleWindowView> {
  bool _showSettings = false;

  @override
  Widget build(BuildContext context) {
    final snapshot = widget.snapshot;
    final preferences = snapshot.displayPreferences;
    final colors = Theme.of(context).colorScheme;
    final primary = preferences.highContrast ? Colors.white : colors.onSurface;
    final secondary = preferences.highContrast
        ? const Color(0xFFC8D2DE)
        : colors.onSurfaceVariant;
    final accent = preferences.highContrast
        ? Color(preferences.colorPreset.darkAccentArgb)
        : Color(preferences.colorPreset.lightAccentArgb);
    final cue = snapshot.cues.isEmpty ? null : snapshot.cues.last;

    return ColoredBox(
      color: preferences.highContrast
          ? const Color(0xFF101820)
          : colors.surface,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 8, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: DragToMoveArea(
                      child: _SubtitleWindowHeader(
                        snapshot: snapshot,
                        primary: primary,
                        secondary: secondary,
                        accent: accent,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: _showSettings ? '关闭字幕设置' : '字幕设置',
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    onPressed: () =>
                        setState(() => _showSettings = !_showSettings),
                    icon: Icon(
                      _showSettings
                          ? Icons.closed_caption_rounded
                          : Icons.tune_rounded,
                      color: secondary,
                      size: 18,
                    ),
                  ),
                  if (widget.onClose != null)
                    SizedBox(
                      width: 32,
                      height: 30,
                      child: IconButton(
                        tooltip: '关闭字幕窗',
                        padding: EdgeInsets.zero,
                        iconSize: 18,
                        onPressed: widget.onClose,
                        icon: Icon(Icons.close_rounded, color: secondary),
                      ),
                    ),
                ],
              ),
              Divider(
                height: 6,
                thickness: 1,
                color: preferences.highContrast
                    ? const Color(0xFF34414D)
                    : colors.outlineVariant,
              ),
              Expanded(
                child: _showSettings
                    ? _SubtitleWindowSettings(
                        snapshot: snapshot,
                        message: widget.controlMessage,
                        onAction: widget.onControlAction,
                      )
                    : cue == null
                    ? _SubtitleWindowEmptyState(
                        status: snapshot.sessionStatus,
                        color: secondary,
                      )
                    : _SubtitleWindowCueView(
                        key: ValueKey<String>(
                          cue.cueId ??
                              '${snapshot.sessionId}:${snapshot.cues.length - 1}',
                        ),
                        cue: cue,
                        mode: preferences.mode,
                        fontSize: preferences.fontScale.fontSize,
                        primary: primary,
                        secondary: secondary,
                        accent: accent,
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _SubtitleWindowSettings extends StatelessWidget {
  const _SubtitleWindowSettings({
    required this.snapshot,
    required this.message,
    required this.onAction,
  });

  final SubtitleWindowSnapshot snapshot;
  final String? message;
  final ValueChanged<SubtitleWindowControlAction>? onAction;

  @override
  Widget build(BuildContext context) {
    final preferences = snapshot.displayPreferences;
    final colors = Theme.of(context).colorScheme;
    final foreground = preferences.highContrast
        ? Colors.white
        : colors.onSurface;

    Widget section(String label) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: preferences.highContrast
              ? const Color(0xFFAAB6C4)
              : colors.onSurfaceVariant,
        ),
      ),
    );

    Widget choice(
      String label,
      bool selected,
      SubtitleWindowControlAction action, {
      Color? swatch,
      bool enabled = true,
    }) => ActionChip(
      avatar: swatch == null
          ? null
          : CircleAvatar(backgroundColor: swatch, radius: 7),
      label: Text(label),
      labelStyle: TextStyle(
        color: foreground,
        fontSize: 12,
        fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
      ),
      backgroundColor: selected
          ? (preferences.highContrast
                ? const Color(0xFF203547)
                : colors.secondaryContainer)
          : (preferences.highContrast
                ? const Color(0xFF151D26)
                : colors.surfaceContainerLow),
      side: BorderSide(
        color: selected
            ? (preferences.highContrast
                  ? const Color(0xFF4D9AB8)
                  : colors.primary)
            : (preferences.highContrast
                  ? const Color(0xFF34414D)
                  : colors.outlineVariant),
      ),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      onPressed: enabled && onAction != null ? () => onAction!(action) : null,
    );

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 4,
            runSpacing: 2,
            children: [
              section('字幕'),
              choice(
                '双语',
                preferences.mode == SubtitleDisplayMode.bilingual,
                SubtitleWindowControlAction.displayBilingual,
              ),
              choice(
                '原文',
                preferences.mode == SubtitleDisplayMode.sourceOnly,
                SubtitleWindowControlAction.displaySourceOnly,
              ),
              choice(
                '译文',
                preferences.mode == SubtitleDisplayMode.translatedOnly,
                SubtitleWindowControlAction.displayTranslatedOnly,
              ),
              section('字号'),
              choice(
                '18',
                preferences.fontScale == SubtitleFontScale.compact,
                SubtitleWindowControlAction.fontCompact,
              ),
              choice(
                '21',
                preferences.fontScale == SubtitleFontScale.standard,
                SubtitleWindowControlAction.fontStandard,
              ),
              choice(
                '25',
                preferences.fontScale == SubtitleFontScale.large,
                SubtitleWindowControlAction.fontLarge,
              ),
            ],
          ),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 4,
            runSpacing: 2,
            children: [
              section('字幕色'),
              for (final preset in SubtitleColorPreset.values)
                choice(
                  preset.label,
                  preferences.colorPreset == preset,
                  switch (preset) {
                    SubtitleColorPreset.ice =>
                      SubtitleWindowControlAction.colorIce,
                    SubtitleColorPreset.amber =>
                      SubtitleWindowControlAction.colorAmber,
                    SubtitleColorPreset.mint =>
                      SubtitleWindowControlAction.colorMint,
                    SubtitleColorPreset.rose =>
                      SubtitleWindowControlAction.colorRose,
                  },
                  swatch: Color(
                    preferences.highContrast
                        ? preset.darkAccentArgb
                        : preset.lightAccentArgb,
                  ),
                ),
              choice(
                '高对比底色',
                preferences.highContrast,
                SubtitleWindowControlAction.toggleHighContrast,
              ),
              section('透明度'),
              for (final (opacity, action, label)
                  in const <(double, SubtitleWindowControlAction, String)>[
                    (0.72, SubtitleWindowControlAction.opacityLight, '72%'),
                    (0.82, SubtitleWindowControlAction.opacityBalanced, '82%'),
                    (0.92, SubtitleWindowControlAction.opacityClear, '92%'),
                  ])
                choice(
                  label,
                  (preferences.windowOpacity - opacity).abs() < 0.01,
                  action,
                ),
            ],
          ),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 4,
            runSpacing: 2,
            children: [
              ActionChip(
                avatar: const Icon(Icons.swap_horiz_rounded, size: 16),
                label: Text(
                  '${snapshot.sourceLanguageLabel} → '
                  '${snapshot.targetLanguageLabel} · '
                  '${snapshot.sessionStatus == SubtitleSessionStatus.capturing || snapshot.sessionStatus == SubtitleSessionStatus.paused ? '反向并新开会话' : '反向'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onPressed: snapshot.canChangeDirection && onAction != null
                    ? () =>
                          onAction!(SubtitleWindowControlAction.switchDirection)
                    : null,
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              ActionChip(
                avatar: Icon(
                  snapshot.audioRecordingActive
                      ? Icons.mic_rounded
                      : Icons.mic_none_rounded,
                  size: 16,
                ),
                label: Text(
                  snapshot.audioRecordingActive ? '录音 · 正在保存' : '开始录音',
                ),
                onPressed: onAction == null
                    ? null
                    : () => onAction!(
                        SubtitleWindowControlAction.toggleAudioRecording,
                      ),
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              ActionChip(
                avatar: Icon(
                  snapshot.screenRecordingActive
                      ? Icons.stop_screen_share_rounded
                      : Icons.screen_share_rounded,
                  size: 16,
                ),
                label: Text(
                  snapshot.screenRecordingActive
                      ? '停止录屏并保存'
                      : snapshot.screenRecordingHasTarget
                      ? '开始录屏'
                      : '选择画面并录屏',
                ),
                onPressed: onAction == null
                    ? null
                    : () => onAction!(
                        SubtitleWindowControlAction.toggleScreenRecording,
                      ),
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ],
          ),
          if (message != null && message!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 6, top: 2),
              child: Text(
                message!,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: preferences.highContrast
                      ? const Color(0xFF8FDFFF)
                      : colors.primary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
    );
  }
}

final class _SubtitleWindowHeader extends StatelessWidget {
  const _SubtitleWindowHeader({
    required this.snapshot,
    required this.primary,
    required this.secondary,
    required this.accent,
  });

  final SubtitleWindowSnapshot snapshot;
  final Color primary;
  final Color secondary;
  final Color accent;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(Icons.subtitles_rounded, color: accent, size: 18),
      const SizedBox(width: 7),
      Expanded(
        child: Text(
          '实时字幕 · ${snapshot.sourceLanguageLabel} → ${snapshot.targetLanguageLabel}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.titleSmall
              ?.copyWith(color: primary, fontWeight: FontWeight.w700),
        ),
      ),
      const SizedBox(width: 8),
      _StatusDot(
        status: snapshot.sessionStatus,
        color: secondary,
        accent: accent,
      ),
    ],
  );
}

final class _StatusDot extends StatelessWidget {
  const _StatusDot({
    required this.status,
    required this.color,
    required this.accent,
  });

  final SubtitleSessionStatus status;
  final Color color;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final active = status == SubtitleSessionStatus.capturing;
    final foreground = status == SubtitleSessionStatus.failed
        ? const Color(0xFFFF8A80)
        : active
        ? accent
        : color;
    final label = switch (status) {
      SubtitleSessionStatus.idle => '待开始',
      SubtitleSessionStatus.preparing => '准备中',
      SubtitleSessionStatus.capturing => '进行中',
      SubtitleSessionStatus.paused => '已暂停',
      SubtitleSessionStatus.stopping => '保存中',
      SubtitleSessionStatus.stopped => '已结束',
      SubtitleSessionStatus.failed => '异常',
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (active)
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: foreground,
              shape: BoxShape.circle,
            ),
          ),
        if (active) const SizedBox(width: 5),
        Text(
          label,
          style: Theme.of(context).textTheme.labelSmall
              ?.copyWith(color: foreground, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}

final class _SubtitleWindowCueView extends StatelessWidget {
  const _SubtitleWindowCueView({
    required this.cue,
    required this.mode,
    required this.fontSize,
    required this.primary,
    required this.secondary,
    required this.accent,
    super.key,
  });

  final SubtitleWindowCue cue;
  final SubtitleDisplayMode mode;
  final double fontSize;
  final Color primary;
  final Color secondary;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final source = cue.sourceText.trim();
    final translated = cue.translatedText?.trim();
    final hasTranslation = translated != null && translated.isNotEmpty;
    final showSource =
        mode != SubtitleDisplayMode.translatedOnly || !hasTranslation;
    final showTranslation = mode != SubtitleDisplayMode.sourceOnly;
    final languageCode = cue.languageCode?.trim();
    final language = languageCode == null || languageCode.isEmpty
        ? null
        : AsrLanguageRegistry.displayLabel(languageCode);
    final pending = cue.translationStatusLabel?.trim();
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 2, 3, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (showSource && source.isNotEmpty)
            Text(
              formatSubtitleTextForDisplay(
                source,
                languageCode: languageCode ?? '',
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontSize: fontSize,
                height: 1.2,
                color: cue.sourceIsFinal ? primary : secondary,
                fontWeight: cue.sourceIsFinal
                    ? FontWeight.w700
                    : FontWeight.w400,
              ),
            ),
          if (showTranslation) ...[
            if (showSource && source.isNotEmpty) const SizedBox(height: 2),
            Text(
              hasTranslation
                  ? translated
                  : (pending?.isNotEmpty == true ? pending! : '翻译中…'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                fontSize: fontSize - 1,
                height: 1.2,
                color: hasTranslation ? accent : secondary,
                fontWeight: hasTranslation ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
          if (language != null && source.isEmpty)
            Text(
              language,
              style: Theme.of(context).textTheme.labelSmall
                  ?.copyWith(color: secondary),
            ),
        ],
      ),
    );
  }
}

final class _SubtitleWindowEmptyState extends StatelessWidget {
  const _SubtitleWindowEmptyState({required this.status, required this.color});

  final SubtitleSessionStatus status;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final label = switch (status) {
      SubtitleSessionStatus.idle => '开始同传后，字幕会显示在这里',
      SubtitleSessionStatus.preparing => '正在准备音源…',
      SubtitleSessionStatus.capturing => '等待语音字幕…',
      SubtitleSessionStatus.paused => '同传已暂停',
      SubtitleSessionStatus.stopping => '正在保存字幕…',
      SubtitleSessionStatus.stopped => '本次同传已结束',
      SubtitleSessionStatus.failed => '同传遇到问题，请查看主窗口',
    };
    return Align(
      alignment: Alignment.centerLeft,
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: color),
      ),
    );
  }
}

String _stringValue(Object? value, {required String fallback}) =>
    value is String ? value : fallback;

T _enumByName<T extends Enum>(List<T> values, Object? name, T fallback) {
  for (final value in values) {
    if (value.name == name) return value;
  }
  return fallback;
}
