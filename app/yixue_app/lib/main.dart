import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:file_selector/file_selector.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';
import 'package:yixue_app/app/app_appearance.dart';
import 'package:yixue_app/app/app_theme.dart';
import 'package:yixue_app/app/yixue_app.dart';
import 'package:yixue_app/core/app_data_directory.dart';
import 'package:yixue_app/core/app_instance_lease.dart';
import 'package:yixue_app/core/desktop_window_startup.dart';
import 'package:yixue_app/core/native_core_bridge.dart';
import 'package:yixue_app/core/ui_preference_store.dart';
import 'package:yixue_app/core/translation_preferences.dart';
import 'package:yixue_app/core/translation_terminology.dart';
import 'package:yixue_app/core/dictionary_preferences.dart';
import 'package:yixue_app/core/home_plan.dart';
import 'package:yixue_app/core/home_daily_plan_store.dart';
import 'package:yixue_app/core/home_focus_session_store.dart';
import 'package:yixue_app/core/home_user_profile_store.dart';
import 'package:yixue_app/core/learning_workbench.dart';
import 'package:yixue_app/core/learning_textbook_catalog.dart';
import 'package:yixue_app/core/storage_policy.dart';
import 'package:yixue_app/features/brand/brand_mark.dart';
import 'package:yixue_app/features/brand/app_startup_gate.dart';
import 'package:yixue_app/features/brand/launch_gate.dart';
import 'package:yixue_app/features/brand/startup_error_page.dart';
import 'package:yixue_app/features/screenshot_translation/screenshot_translation_window_entry.dart';
import 'package:yixue_app/features/simultaneous_interpretation/subtitle_session_store.dart';
import 'package:yixue_app/features/simultaneous_interpretation/subtitle_window_runtime.dart';

const MethodChannel _supervisorReadinessChannel = MethodChannel(
  'com.yixue.yixue_app/supervisor',
);

const WindowOptions _mainWindowOptions = WindowOptions(
  size: Size(1280, 720),
  minimumSize: Size(960, 620),
  center: true,
  title: '译学',
  titleBarStyle: TitleBarStyle.hidden,
  windowButtonVisibility: false,
);

const Duration _firstFramePresentationTimeout = Duration(seconds: 90);

Future<void> _signalSupervisorAppReady() async {
  if (!Platform.isWindows) return;
  try {
    await _supervisorReadinessChannel.invokeMethod<void>('signalAppReady');
  } on Object catch (error, stack) {
    stderr.writeln('Unable to notify the Windows supervisor: $error');
    Error.throwWithStackTrace(error, stack);
  }
}

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  final supervisorWindowPresented = Completer<void>();
  debugPaintBaselinesEnabled = false;
  Object? entryError;
  StackTrace? entryStackTrace;
  if (Platform.isWindows && hasSubtitleWindowChildArgument(arguments)) {
    try {
      await runSubtitleWindowIfRequested(arguments);
    } catch (error) {
      stderr.writeln('Subtitle window startup failed: $error');
      exit(1);
    }
    return;
  }
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    try {
      final controller = await WindowController.fromCurrentEngine().timeout(
        const Duration(seconds: 5),
      );
      if (controller.arguments.isNotEmpty) {
        await runScreenshotTranslationChildWindow(controller);
        return;
      }
    } catch (error, stackTrace) {
      // Keep the desktop entry visible if child-window routing fails before the
      // normal startup gate is mounted. The gate will show the error and let
      // the user retry or select a different local data directory.
      entryError = error;
      entryStackTrace = stackTrace;
    }
  }
  final preferenceStore = _dataDirectoryPreferenceStore();
  var showEntryError = entryError != null;
  runApp(
    _startupGate(
      start: (configurePresentation) {
        if (showEntryError) {
          showEntryError = false;
          return Future<Widget>.error(entryError!, entryStackTrace);
        }
        return _initializeMainApp(
          preferenceStore,
          configurePresentation: configurePresentation,
          supervisorWindowPresented: supervisorWindowPresented.future,
        );
      },
      preferenceStore: preferenceStore,
      supervisorWindowPresented: supervisorWindowPresented.future,
    ),
  );
  if (Platform.isWindows) {
    final firstFrameRasterized =
        WidgetsBinding.instance.waitUntilFirstFrameRasterized;
    final windowPresentation = showMainWindowAfterFirstRasterizedFrame(
      firstFrameRasterized: firstFrameRasterized,
      prepareWindow: () => prepareMainDesktopWindow(
        initialize: windowManager.ensureInitialized,
        configure: () => windowManager.waitUntilReadyToShow(_mainWindowOptions),
      ),
      showWindow: windowManager.show,
      focusWindow: windowManager.focus,
      isWindowVisible: windowManager.isVisible,
      onFocusFailure: (error, stackTrace) {
        stderr.writeln('The Yixue window is visible but not focused: $error');
        stderr.writeln(stackTrace);
      },
      onPresentationFailure: (error, stackTrace) async {
        stderr.writeln('Unable to prepare the Yixue main window: $error');
        stderr.writeln(stackTrace);
        try {
          await windowManager.show().timeout(const Duration(seconds: 5));
          final visible = await waitForWindowVisibility(
            isWindowVisible: windowManager.isVisible,
          );
          if (!visible) return false;
          try {
            await windowManager.focus().timeout(const Duration(seconds: 5));
          } on Object catch (focusError, focusStackTrace) {
            stderr.writeln(
              'The recovered Yixue window is visible but not focused: '
              '$focusError',
            );
            stderr.writeln(focusStackTrace);
          }
          return visible;
        } on Object catch (fallbackError, fallbackStackTrace) {
          stderr.writeln(
            'Unable to recover main-window visibility: $fallbackError',
          );
          stderr.writeln(fallbackStackTrace);
          return false;
        }
      },
    );
    final presentationResult = await observeSupervisorWindowPresentation(
      windowPresentation: windowPresentation,
      supervisorWindowPresented: supervisorWindowPresented,
      timeout: _firstFramePresentationTimeout,
      firstFrameRasterized: firstFrameRasterized,
      isWindowVisible: windowManager.isVisible,
      onTimeout: () {
        stderr.writeln(
          'Flutter has not presented the Yixue window within '
          '${_firstFramePresentationTimeout.inSeconds} seconds. '
          'Late first-frame completion will still reveal the window; '
          'the Windows supervisor remains available to wait or cancel.',
        );
      },
      onFailure: (error, stackTrace) {
        stderr.writeln('Unable to present the Yixue window: $error');
        stderr.writeln(stackTrace);
      },
    );
    if (presentationResult == false) {
      stderr.writeln(
        'The Yixue window could not be made visible after bounded recovery. '
        'The Windows supervisor will keep the launch recoverable.',
      );
    }
  }
}

Future<Widget> _initializeMainApp(
  AppDataDirectoryPreferenceStore preferenceStore, {
  required ValueChanged<YixueLaunchPresentation> configurePresentation,
  required Future<void> supervisorWindowPresented,
}) async {
  final dataDirectory = await _resolveDataDirectory();
  final launchPresentation = dataDirectory == null
      ? const YixueLaunchPresentation(motionLevel: YixueMotionLevel.off)
      : await _readLaunchPresentation(dataDirectory);
  configurePresentation(launchPresentation);

  if (!Platform.isWindows && (Platform.isLinux || Platform.isMacOS)) {
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(_mainWindowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }

  if (dataDirectory == null) {
    return _DataDirectorySetupApp(
      defaultDirectory: _defaultDataDirectory(),
      preferenceStore: preferenceStore,
      supervisorWindowPresented: supervisorWindowPresented,
    );
  }
  try {
    final subtitleSessionStore = await _openSubtitleSessionStore(dataDirectory);
    final app = _buildYixueApp(
      dataDirectory,
      subtitleSessionStore,
      launchVariant: launchPresentation.variant,
    );
    await _markLaunchSuccessful(dataDirectory);
    return app;
  } catch (_) {
    await AppInstanceLease.releaseProcessLeaseAfterFailedLaunch();
    rethrow;
  }
}

Future<Widget> _buildConfiguredYixueApp(
  Directory dataDirectory, {
  required ValueChanged<YixueLaunchPresentation> configurePresentation,
}) async {
  final presentation = await _readLaunchPresentation(dataDirectory);
  configurePresentation(presentation);
  try {
    final subtitleSessionStore = await _openSubtitleSessionStore(dataDirectory);
    final app = _buildYixueApp(
      dataDirectory,
      subtitleSessionStore,
      launchVariant: presentation.variant,
    );
    await _markLaunchSuccessful(dataDirectory);
    return app;
  } catch (_) {
    await AppInstanceLease.releaseProcessLeaseAfterFailedLaunch();
    rethrow;
  }
}

Widget _startupGate({
  required Future<Widget> Function(
    ValueChanged<YixueLaunchPresentation> configurePresentation,
  )
  start,
  required AppDataDirectoryPreferenceStore preferenceStore,
  required Future<void> supervisorWindowPresented,
}) => _StartupExperience(
  start: start,
  preferenceStore: preferenceStore,
  supervisorWindowPresented: supervisorWindowPresented,
);

Future<YixueLaunchVariant> _launchVariant(Directory dataDirectory) async {
  final marker = File('${dataDirectory.path}\\.yixue-launched');
  if (await marker.exists()) return YixueLaunchVariant.compact;
  return YixueLaunchVariant.full;
}

Future<YixueLaunchPresentation> _readLaunchPresentation(
  Directory dataDirectory,
) async {
  final values = await Future.wait<Object?>([
    _launchVariant(dataDirectory),
    FileAppearancePreferenceStore(
      File('${dataDirectory.path}\\appearance-preferences.json'),
    ).read(),
  ]);
  return YixueLaunchPresentation(
    variant: values[0] as YixueLaunchVariant,
    motionLevel:
        (values[1] as AppearanceState?)?.motionLevel ?? YixueMotionLevel.full,
  );
}

Future<void> _markLaunchSuccessful(Directory dataDirectory) async {
  final marker = File('${dataDirectory.path}\\.yixue-launched');
  await marker.parent.create(recursive: true);
  await marker.writeAsString('1', flush: true);
}

Future<Directory?> _resolveDataDirectory() async {
  final configured = Platform.environment['YIXUE_DATA_DIR'];
  if (configured != null && configured.trim().isNotEmpty) {
    return Directory(
      resolveAppDataPath(
        configuredDirectory: configured,
        executablePath: Platform.resolvedExecutable,
      ),
    );
  }
  if (kDebugMode && Platform.isWindows) {
    // A Debug launch must not read the release app-data preference or open a
    // user's library by default. Set YIXUE_DATA_DIR explicitly for isolated QA.
    return Directory(
      isolatedDebugAppDataPath(
        tempDirectoryPath: Directory.systemTemp.path,
        processId: pid,
      ),
    );
  }
  final stored = await _dataDirectoryPreferenceStore().read();
  if (stored == null) return null;
  return Directory(
    resolveAppDataPath(
      configuredDirectory: configured,
      storedDirectory: stored,
      executablePath: Platform.resolvedExecutable,
    ),
  );
}

Directory _defaultDataDirectory() => Directory(
  resolveAppDataPath(
    configuredDirectory: null,
    executablePath: Platform.resolvedExecutable,
  ),
);

AppDataDirectoryPreferenceStore _dataDirectoryPreferenceStore() =>
    AppDataDirectoryPreferenceStore(
      File(
        resolveAppDataPreferenceFilePath(
          executablePath: Platform.resolvedExecutable,
          configuredDirectory: Platform.environment['YIXUE_CONFIG_DIR'],
        ),
      ),
    );

Widget _buildYixueApp(
  Directory dataDirectory,
  SubtitleSessionStore subtitleSessionStore, {
  required YixueLaunchVariant launchVariant,
}) => YixueApp(
  appDataDirectory: dataDirectory.path,
  subtitleSessionStore: subtitleSessionStore,
  coreFactory: () => _openPersistentCore(dataDirectory),
  sidebarPreferenceStore: FileUiPreferenceStore(
    File('${dataDirectory.path}\\ui-preferences.json'),
  ),
  appearancePreferenceStore: FileAppearancePreferenceStore(
    File('${dataDirectory.path}\\appearance-preferences.json'),
  ),
  translationPreferencesStore: FileTranslationPreferencesStore(
    File('${dataDirectory.path}\\translation-preferences.json'),
  ),
  translationTerminologyStore: FileTranslationTerminologyStore(
    File('${dataDirectory.path}\\translation-terminology.json'),
  ),
  dictionaryPreferencesStore: FileDictionaryPreferencesStore(
    File('${dataDirectory.path}\\dictionary-preferences.json'),
  ),
  homePlanStore: FileHomePlanStore(
    File('${dataDirectory.path}\\home-plan.json'),
  ),
  homeDailyPlanStore: FileHomeDailyPlanStore(
    File('${dataDirectory.path}\\home-daily-plans.json'),
  ),
  homeFocusSessionStore: FileHomeFocusSessionStore(
    File('${dataDirectory.path}\\home-focus-session.json'),
  ),
  homeUserProfileStore: FileHomeUserProfileStore(
    File('${dataDirectory.path}\\home-user-profile.json'),
  ),
  learningStore: FileLearningStore(
    File('${dataDirectory.path}\\learning-workspace.json'),
  ),
  textbookStore: FileLearningTextbookStore(
    File('${dataDirectory.path}\\learning-textbooks.json'),
  ),
  storagePolicyStore: FileStoragePolicyStore(
    File('${dataDirectory.path}\\storage-policy.json'),
  ),
  showLaunchAnimation: false,
  launchVariant: launchVariant,
);

Future<SubtitleSessionStore> _openSubtitleSessionStore(
  Directory dataDirectory,
) async {
  final lease = await AppInstanceLease.acquire(dataDirectory);
  try {
    final store = FileSubtitleSessionStore(
      Directory(joinAppDataPath(dataDirectory.path, 'subtitle-sessions')),
    );
    await store.recoverInterruptedSessions();
    AppInstanceLease.retainForProcessLifetime(lease);
    return store;
  } catch (_) {
    await AppInstanceLease.releaseAfterFailedLaunch(lease);
    rethrow;
  }
}

class _StartupExperience extends StatefulWidget {
  const _StartupExperience({
    required this.start,
    required this.preferenceStore,
    required this.supervisorWindowPresented,
  });

  final Future<Widget> Function(
    ValueChanged<YixueLaunchPresentation> configurePresentation,
  )
  start;
  final AppDataDirectoryPreferenceStore preferenceStore;
  final Future<void> supervisorWindowPresented;

  @override
  State<_StartupExperience> createState() => _StartupExperienceState();
}

class _StartupExperienceState extends State<_StartupExperience> {
  late final ValueNotifier<YixueLaunchPresentation> _presentation;

  @override
  void initState() {
    super.initState();
    _presentation = ValueNotifier(const YixueLaunchPresentation());
  }

  @override
  void dispose() {
    _presentation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AppStartupGate(
    start: () => widget.start((presentation) {
      _presentation.value = presentation;
    }),
    loading: const _StartupLoadingPage(),
    errorBuilder: (context, error, _, retry, recover) => AppStartupErrorPage(
      error: error,
      onRetry: retry,
      onChooseData: recover,
    ),
    recoveryBuilder: () => _DataDirectorySetupApp(
      defaultDirectory: _defaultDataDirectory(),
      preferenceStore: widget.preferenceStore,
      supervisorWindowPresented: widget.supervisorWindowPresented,
    ),
    onReady: Platform.isWindows
        ? () => signalSupervisorReadyAfterPresentation(
            windowPresented: widget.supervisorWindowPresented,
            signalReady: _signalSupervisorAppReady,
          )
        : null,
    launchPresentation: _presentation,
  );
}

class _StartupLoadingPage extends StatelessWidget {
  const _StartupLoadingPage();

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: '译学',
    theme: AppTheme.vitality(),
    home: Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(width: 92, height: 92, child: YixueBrandMark()),
            const SizedBox(height: 18),
            Text('正在准备译学', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 18),
            const SizedBox(
              width: 180,
              child: LinearProgressIndicator(minHeight: 3),
            ),
          ],
        ),
      ),
    ),
  );
}

class _DataDirectorySetupApp extends StatefulWidget {
  const _DataDirectorySetupApp({
    required this.defaultDirectory,
    required this.preferenceStore,
    required this.supervisorWindowPresented,
  });

  final Directory defaultDirectory;
  final AppDataDirectoryPreferenceStore preferenceStore;
  final Future<void> supervisorWindowPresented;

  @override
  State<_DataDirectorySetupApp> createState() => _DataDirectorySetupAppState();
}

class _DataDirectorySetupAppState extends State<_DataDirectorySetupApp> {
  Directory? _selectedDirectory;
  String? _error;
  var _busy = false;

  Future<void> _pickDirectory() async {
    try {
      final path = await getDirectoryPath(
        initialDirectory: widget.defaultDirectory.parent.path,
        confirmButtonText: '选择此资料库',
      );
      if (path == null || path.trim().isEmpty || !mounted) return;
      await _saveDirectory(Directory(path.trim()).absolute);
    } catch (error) {
      if (mounted) {
        setState(() => _error = '无法打开文件夹选择器：$error');
      }
    }
  }

  Future<void> _useDefaultDirectory() async {
    await _saveDirectory(widget.defaultDirectory);
  }

  Future<void> _saveDirectory(Directory directory) async {
    if (_busy) return;
    final normalized = directory.absolute;
    if (_isWindowsSystemDirectory(normalized.path)) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('确认使用 C 盘？'),
          content: const Text('你选择了系统盘。按照隐私约定，只有你明确确认后，译学才会把数据库、模型和缓存放在 C 盘。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('返回选择'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认使用 C 盘'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.preferenceStore.write(normalized.path);
      if (mounted) setState(() => _selectedDirectory = normalized);
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '资料库位置保存失败：$error';
        });
      }
    }
  }

  bool _isWindowsSystemDirectory(String path) =>
      Platform.isWindows && RegExp(r'^[cC]:([\\/]|$)').hasMatch(path);

  @override
  Widget build(BuildContext context) {
    final selected = _selectedDirectory;
    if (selected != null) {
      return _startupGate(
        start: (configurePresentation) => _buildConfiguredYixueApp(
          selected,
          configurePresentation: configurePresentation,
        ),
        preferenceStore: widget.preferenceStore,
        supervisorWindowPresented: widget.supervisorWindowPresented,
      );
    }
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: '译学资料库设置',
      theme: AppTheme.vitality(),
      home: Scaffold(
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: Padding(
              padding: const EdgeInsets.all(42),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 132,
                    height: 132,
                    child: YixueBrandMark(),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    '译学资料库',
                    style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    '首次启动请选择保存位置。建议使用空间充足的非系统盘；数据库、模型、缓存和临时文件都会跟随这个位置。',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 14),
                  SelectableText(
                    '建议位置：${widget.defaultDirectory.path}',
                    textAlign: TextAlign.center,
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 14),
                    Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    alignment: WrapAlignment.center,
                    children: [
                      FilledButton.icon(
                        onPressed: _busy ? null : _pickDirectory,
                        icon: const Icon(Icons.folder_open_rounded),
                        label: const Text('选择资料库位置'),
                      ),
                      OutlinedButton(
                        onPressed: _busy ? null : _useDefaultDirectory,
                        child: const Text('使用建议位置'),
                      ),
                    ],
                  ),
                  if (_busy) ...[
                    const SizedBox(height: 18),
                    const LinearProgressIndicator(),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

AppCore _openPersistentCore(Directory dataDirectory) {
  dataDirectory.createSync(recursive: true);
  return NativeCoreBridge.open(databasePath: '${dataDirectory.path}\\yixue.db');
}
