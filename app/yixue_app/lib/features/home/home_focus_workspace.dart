import 'dart:async';

import 'package:flutter/material.dart';
import 'package:yixue_app/core/home_workbench.dart';
import 'package:yixue_app/core/native_core_bridge.dart';

typedef HomeFocusSessionLoader = Future<HomeFocusSessionData?> Function();
typedef HomeFocusSessionSaver = Future<void> Function(
  HomeFocusSessionData session,
);
typedef HomeFocusSessionClearer = Future<void> Function();
typedef HomeFocusActivityRecorder = Future<void> Function(
  ActivityEventData activity,
);

/// A local Pomodoro-style workspace. The timer state is persisted at every
/// meaningful transition, so a restart can recover the current phase without
/// keeping a process alive in the background.
class HomeFocusWorkspace extends StatefulWidget {
  const HomeFocusWorkspace({
    required this.loadSession,
    required this.saveSession,
    required this.clearSession,
    this.recordActivity,
    this.clock = DateTime.now,
    super.key,
  });

  final HomeFocusSessionLoader loadSession;
  final HomeFocusSessionSaver saveSession;
  final HomeFocusSessionClearer clearSession;
  final HomeFocusActivityRecorder? recordActivity;
  final DateTime Function() clock;

  @override
  State<HomeFocusWorkspace> createState() => _HomeFocusWorkspaceState();
}

class _HomeFocusWorkspaceState extends State<HomeFocusWorkspace> {
  final _title = TextEditingController(text: '专注学习');
  Timer? _timer;
  HomeFocusSessionData? _session;
  var _loading = true;
  var _saving = false;
  var _transitioning = false;
  var _ending = false;
  var _focusMinutes = 50;
  var _restMinutes = 10;
  var _targetCycles = 4;
  String? _status;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _title.dispose();
    super.dispose();
  }

  Future<void> _restore() async {
    try {
      final session = await widget.loadSession();
      if (!mounted) return;
      setState(() {
        _session = session;
        _loading = false;
        if (session != null) {
          _focusMinutes = session.focusDurationSeconds ~/ 60;
          _restMinutes = session.restDurationSeconds ~/ 60;
          _targetCycles = session.targetCycles;
          _title.text = session.title;
        }
      });
      if (session?.running == true) {
        _timer ??= Timer.periodic(const Duration(seconds: 1), (_) => _tick());
        unawaited(_tick());
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _status = '专注记录读取失败，可以重新开始一轮';
        });
      }
    }
  }

  int _elapsed(HomeFocusSessionData session) {
    if (!session.running || session.startedAt == null) {
      return session.elapsedSeconds;
    }
    final started = DateTime.tryParse(session.startedAt!);
    if (started == null) return session.elapsedSeconds;
    final extra = widget.clock().difference(started).inSeconds;
    return session.elapsedSeconds + (extra < 0 ? 0 : extra);
  }

  String _formatSeconds(int total) {
    final seconds = total.clamp(0, 99 * 60 * 60).toInt();
    final minutes = seconds ~/ 60;
    final remainder = seconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${remainder.toString().padLeft(2, '0')}';
  }

  HomeFocusSessionData _replace(
    HomeFocusSessionData session, {
    String? phase,
    int? completedCycles,
    int? elapsedSeconds,
    String? startedAt,
    bool? running,
  }) => HomeFocusSessionData(
    id: session.id,
    title: session.title,
    phase: phase ?? session.phase,
    focusDurationSeconds: session.focusDurationSeconds,
    restDurationSeconds: session.restDurationSeconds,
    targetCycles: session.targetCycles,
    completedCycles: completedCycles ?? session.completedCycles,
    elapsedSeconds: elapsedSeconds ?? session.elapsedSeconds,
    startedAt: startedAt,
    running: running ?? session.running,
    updatedAt: widget.clock().toIso8601String(),
  );

  Future<void> _persist(HomeFocusSessionData session) async {
    _session = session;
    await widget.saveSession(session);
  }

  Future<void> _start() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _status = null;
    });
    final now = widget.clock();
    final current = _session;
    final session = current == null
        ? HomeFocusSessionData(
            id: 'focus-${now.microsecondsSinceEpoch}',
            title: _title.text.trim().isEmpty ? '专注学习' : _title.text.trim(),
            phase: 'focus',
            focusDurationSeconds: _focusMinutes * 60,
            restDurationSeconds: _restMinutes * 60,
            targetCycles: _targetCycles,
            completedCycles: 0,
            elapsedSeconds: 0,
            startedAt: now.toIso8601String(),
            running: true,
            updatedAt: now.toIso8601String(),
          )
        : _replace(
            current,
            elapsedSeconds: _elapsed(current),
            startedAt: now.toIso8601String(),
            running: true,
          );
    try {
      await _persist(session);
      if (!mounted) return;
      _timer ??= Timer.periodic(const Duration(seconds: 1), (_) => _tick());
      setState(() => _saving = false);
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _status = '专注记录保存失败，请检查本地资料库';
        });
      }
    }
  }

  Future<void> _pause() async {
    final current = _session;
    if (current == null || !current.running || _saving) return;
    setState(() => _saving = true);
    try {
      await _persist(
        _replace(
          current,
          elapsedSeconds: _elapsed(current),
          startedAt: null,
          running: false,
        ),
      );
      if (mounted) setState(() => _saving = false);
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _status = '暂停状态保存失败';
        });
      }
    }
  }

  Future<void> _tick() async {
    final current = _session;
    if (current == null || !current.running || _transitioning) return;
    if (_elapsed(current) <
        (current.phase == 'focus'
            ? current.focusDurationSeconds
            : current.restDurationSeconds)) {
      if (mounted) setState(() {});
      return;
    }
    _transitioning = true;
    try {
      await _advancePhase(current);
    } finally {
      _transitioning = false;
    }
  }

  Future<void> _advancePhase(HomeFocusSessionData current) async {
    final now = widget.clock();
    if (current.phase == 'focus') {
      await _recordFocus(current);
      final completed = current.completedCycles + 1;
      if (completed >= current.targetCycles ||
          current.restDurationSeconds == 0) {
        await _finish('本轮专注完成，做得很好');
        return;
      }
      await _persist(
        _replace(
          current,
          phase: 'rest',
          completedCycles: completed,
          elapsedSeconds: 0,
          startedAt: now.toIso8601String(),
          running: true,
        ),
      );
      if (mounted) setState(() => _status = '专注完成，进入休息');
      return;
    }

    if (current.completedCycles >= current.targetCycles) {
      await _finish('本轮专注完成，做得很好');
      return;
    }
    await _persist(
      _replace(
        current,
        phase: 'focus',
        elapsedSeconds: 0,
        startedAt: now.toIso8601String(),
        running: true,
      ),
    );
    if (mounted) setState(() => _status = '休息结束，开始下一轮专注');
  }

  Future<void> _recordFocus(HomeFocusSessionData session) async {
    final recorder = widget.recordActivity;
    if (recorder == null) return;
    await recorder(
      ActivityEventData(
        id: 'focus:${session.id}:${session.completedCycles + 1}',
        kind: ActivityKind.focus,
        title: session.title,
        detail: '专注计时 · 第 ${session.completedCycles + 1} 轮',
        durationSeconds: session.focusDurationSeconds,
        itemCount: 1,
        occurredAt: widget.clock().toIso8601String(),
      ),
    );
  }

  Future<void> _finish(String message) async {
    if (_ending) return;
    _ending = true;
    try {
      await widget.clearSession();
      if (!mounted) return;
      setState(() {
        _session = null;
        _status = message;
      });
    } finally {
      _ending = false;
    }
  }

  Future<void> _endManually() async {
    final current = _session;
    if (current == null || _ending) return;
    _ending = true;
    try {
      final elapsed = _elapsed(current);
      if (current.phase == 'focus' &&
          elapsed > 0 &&
          widget.recordActivity != null) {
        await widget.recordActivity!(
          ActivityEventData(
            id: 'focus:${current.id}:manual',
            kind: ActivityKind.focus,
            title: current.title,
            detail: '专注计时 · 手动结束',
            durationSeconds: elapsed,
            itemCount: 1,
            occurredAt: widget.clock().toIso8601String(),
          ),
        );
      }
      await widget.clearSession();
      if (!mounted) return;
      setState(() {
        _session = null;
        _status = '本轮专注已保存';
      });
    } finally {
      _ending = false;
    }
  }

  String _phaseLabel(HomeFocusSessionData session) =>
      session.phase == 'focus' ? '专注中' : '休息中';

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final session = _session;
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(42, 30, 42, 34),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 780),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '今日学习',
                style: Theme.of(context).textTheme.headlineMedium
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 6),
              Text(
                '专注学习：把一段时间交给一件事，计时和记录都保存在本地。',
                style: TextStyle(color: colors.onSurfaceVariant),
              ),
              const SizedBox(height: 22),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(28),
                decoration: BoxDecoration(
                  color: colors.surface,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: colors.outline),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x12023A52),
                      blurRadius: 26,
                      offset: Offset(0, 10),
                    ),
                  ],
                ),
                child: session == null
                    ? _buildSetup(context)
                    : _buildRunning(context, session),
              ),
              if (_status != null) ...[
                const SizedBox(height: 14),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: colors.primary.withAlpha(16),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(_status!),
                ),
              ],
              const SizedBox(height: 18),
              Text(
                '说明：软件运行或最小化时会保留计时状态；完全退出后的系统通知将在后续版本单独接入。',
                style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSetup(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '准备开始',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 8),
        TextField(
          key: const ValueKey('focus-title'),
          controller: _title,
          maxLength: 80,
          decoration: const InputDecoration(
            labelText: '这轮专注做什么',
            prefixIcon: Icon(Icons.edit_note_outlined),
          ),
        ),
        const SizedBox(height: 14),
        const Text('专注时长', style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            for (final minutes in [15, 25, 45, 50])
              ChoiceChip(
                key: ValueKey('focus-minutes-$minutes'),
                label: Text('$minutes 分钟'),
                selected: _focusMinutes == minutes,
                onSelected: (_) => setState(() => _focusMinutes = minutes),
              ),
          ],
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<int>(
                initialValue: _restMinutes,
                decoration: const InputDecoration(labelText: '休息时长'),
                items: const [
                  DropdownMenuItem(value: 0, child: Text('不休息')),
                  DropdownMenuItem(value: 3, child: Text('3 分钟')),
                  DropdownMenuItem(value: 5, child: Text('5 分钟')),
                  DropdownMenuItem(value: 10, child: Text('10 分钟')),
                ],
                onChanged: (value) =>
                    setState(() => _restMinutes = value ?? _restMinutes),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: DropdownButtonFormField<int>(
                initialValue: _targetCycles,
                decoration: const InputDecoration(labelText: '专注轮数'),
                items: [
                  for (final cycles in [1, 2, 4, 6, 8])
                    DropdownMenuItem(value: cycles, child: Text('$cycles 轮')),
                ],
                onChanged: (value) =>
                    setState(() => _targetCycles = value ?? _targetCycles),
              ),
            ),
          ],
        ),
        const SizedBox(height: 22),
        FilledButton.icon(
          key: const ValueKey('focus-start'),
          onPressed: _saving ? null : _start,
          icon: const Icon(Icons.play_arrow_rounded),
          label: Text(_saving ? '保存中' : '开始专注'),
        ),
        const SizedBox(height: 8),
        Text(
          '完成一轮后会自动进入休息，并把实际专注时长写入今日总结。',
          style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
        ),
      ],
    );
  }

  Widget _buildRunning(BuildContext context, HomeFocusSessionData session) {
    final colors = Theme.of(context).colorScheme;
    final elapsed = _elapsed(session);
    final total = session.phase == 'focus'
        ? session.focusDurationSeconds
        : session.restDurationSeconds;
    final progress = total == 0 ? 1.0 : (elapsed / total).clamp(0.0, 1.0);
    return Column(
      children: [
        Text(
          _phaseLabel(session),
          style: TextStyle(
            color: session.phase == 'focus' ? colors.primary : colors.tertiary,
            fontSize: 17,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          _formatSeconds(total - elapsed),
          key: const ValueKey('focus-countdown'),
          style: const TextStyle(fontSize: 64, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 6),
        Text(
          '${session.title} · 第 ${session.completedCycles + (session.phase == 'focus' ? 1 : 0)} / ${session.targetCycles} 轮',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 18),
        LinearProgressIndicator(
          value: progress,
          minHeight: 8,
          borderRadius: BorderRadius.circular(5),
          valueColor: AlwaysStoppedAnimation(
            session.phase == 'focus' ? colors.primary : colors.tertiary,
          ),
        ),
        const SizedBox(height: 24),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 10,
          runSpacing: 10,
          children: [
            if (session.running)
              OutlinedButton.icon(
                key: const ValueKey('focus-pause'),
                onPressed: _saving ? null : _pause,
                icon: const Icon(Icons.pause_rounded),
                label: const Text('暂停'),
              )
            else
              FilledButton.icon(
                key: const ValueKey('focus-resume'),
                onPressed: _saving ? null : _start,
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('继续'),
              ),
            TextButton.icon(
              key: const ValueKey('focus-end'),
              onPressed: _ending ? null : _endManually,
              icon: const Icon(Icons.stop_circle_outlined),
              label: const Text('结束并保存'),
            ),
          ],
        ),
      ],
    );
  }
}
