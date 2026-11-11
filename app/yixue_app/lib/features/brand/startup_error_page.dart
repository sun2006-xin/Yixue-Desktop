import 'package:flutter/material.dart';
import 'package:yixue_app/core/app_instance_lease.dart';
import 'package:yixue_app/app/app_theme.dart';

class AppStartupErrorPage extends StatelessWidget {
  const AppStartupErrorPage({
    required this.error,
    required this.onRetry,
    required this.onChooseData,
    super.key,
  });

  final Object error;
  final VoidCallback onRetry;
  final VoidCallback? onChooseData;

  bool get _isInstanceConflict => error is AppInstanceLeaseConflictException;

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: '译学启动',
    theme: AppTheme.vitality(),
    home: Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 660),
          child: Padding(
            padding: const EdgeInsets.all(36),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _isInstanceConflict ? '译学资料库正在使用中' : '译学没有完成启动',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 12),
                Text(
                  _isInstanceConflict
                      ? 'Windows 检测到本地资料库仍被占用。请先等几秒再重新检查；如果“恢复译学”窗口列出了旧进程，请确认程序路径后再选择。为保护字幕和历史记录，请继续使用当前资料库位置。'
                      : onChooseData == null
                      ? '启动准备遇到问题。上一次初始化仍在运行；为避免两个启动流程同时操作资料库，请先等待它结束，再重试或更换资料库位置。'
                      : '启动准备遇到问题。你可以重试，或重新选择本地资料库位置。',
                ),
                const SizedBox(height: 16),
                Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(maxHeight: 150),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(context)
                        .colorScheme
                        .surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(error.toString()),
                  ),
                ),
                const SizedBox(height: 20),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    FilledButton.icon(
                      onPressed: onRetry,
                      icon: const Icon(Icons.refresh_rounded),
                      label: Text(_isInstanceConflict ? '重新检查占用' : '重试启动'),
                    ),
                    if (!_isInstanceConflict && onChooseData != null)
                      OutlinedButton.icon(
                        onPressed: onChooseData,
                        icon: const Icon(Icons.folder_open_rounded),
                        label: const Text('更换资料库位置'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
