import 'package:flutter/material.dart';

/// The ASR route selected for the current source language.
///
/// This is presentation data only. It does not select a model or change the
/// route used by the speech-recognition runtime.
enum AsrRouteKind { englishChineseStreaming, multilingualSegmented }

/// Local model preparation state shown before starting a subtitle session.
enum AsrModelPreparationState { checking, ready, notInstalled, unknown }

/// Read-only summary of the ASR route and model readiness for the current
/// source language.
///
/// Callers remain responsible for supplying the route selected by the runtime
/// and the latest model-store status. This widget intentionally contains no
/// controls and cannot change either value.
class AsrRouteSummary extends StatelessWidget {
  const AsrRouteSummary({
    required this.sourceLanguageLabel,
    required this.routeKind,
    required this.preparationState,
    super.key,
  });

  final String sourceLanguageLabel;
  final AsrRouteKind routeKind;
  final AsrModelPreparationState preparationState;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final route = switch (routeKind) {
      AsrRouteKind.englishChineseStreaming => (
        title: '英中双语流式 ASR',
        mapping: '英语、中文 → 本地 Zipformer 流式识别',
        detail: '字幕随语音持续更新。',
      ),
      AsrRouteKind.multilingualSegmented => (
        title: 'Whisper Tiny 多语言 INT8 + Silero VAD',
        mapping: '日语、韩语、西班牙语、法语、德语、葡萄牙语、俄语和自动识别 → 多语言分段识别',
        detail: '模型约 104 MB；字幕在语音段处理后更新，不是逐帧流式 ASR。',
      ),
    };
    final state = switch (preparationState) {
      AsrModelPreparationState.checking => (
        label: '正在检查本地模型',
        detail: '正在读取本机模型文件。',
        icon: Icons.hourglass_top_rounded,
        color: colors.onSurfaceVariant,
      ),
      AsrModelPreparationState.ready => (
        label: '本地模型已就绪',
        detail: '按当前语种，本次识别将在本机运行。',
        icon: Icons.check_circle_outline_rounded,
        color: colors.primary,
      ),
      AsrModelPreparationState.notInstalled => (
        label: '识别模型未安装',
        detail: '需要先下载对应模型后才能开始识别。',
        icon: Icons.download_outlined,
        color: colors.tertiary,
      ),
      AsrModelPreparationState.unknown => (
        label: '模型状态未知',
        detail: '无法确认安装状态，请重新检查。',
        icon: Icons.help_outline_rounded,
        color: colors.error,
      ),
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '本次识别将使用',
          style: Theme.of(context).textTheme.labelLarge
              ?.copyWith(color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: 4),
        Text(
          route.title,
          style: Theme.of(context).textTheme.titleSmall
              ?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Text('当前原文：$sourceLanguageLabel'),
        const SizedBox(height: 4),
        Text(
          route.mapping,
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: 2),
        Text(
          route.detail,
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(state.icon, size: 18, color: state.color),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    state.label,
                    style: Theme.of(context).textTheme.labelLarge
                        ?.copyWith(color: state.color),
                  ),
                  Text(
                    state.detail,
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: colors.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}
