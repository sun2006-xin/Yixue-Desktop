import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/core/native_core_bridge.dart';
import 'package:yixue_app/core/model_package_discovery_service.dart';
import 'package:yixue_app/core/model_capability_service.dart';
import 'package:yixue_app/core/provider_secret_store.dart';
import 'package:yixue_app/features/settings/model_settings_page.dart';

class _FakeCore implements AppCore, ModelCatalogCore {
  final profiles = <ProviderProfileData>[];
  final catalog = <ModelCatalogEntryData>[];

  @override
  CoreHealth health() =>
      const CoreHealth(schemaVersion: 2, coreVersion: '0.1.0');

  @override
  List<ProviderProfileData> listProviderProfiles() =>
      List.unmodifiable(profiles);

  @override
  void recordActivity(ActivityEventData activity) {}

  @override
  HomeSnapshotData homeSnapshot(String localDate, {int recentLimit = 10}) =>
      const HomeSnapshotData(
        learningMinutes: 0,
        readingPages: 0,
        masteredWords: 0,
        completedExercises: 0,
        recent: [],
      );

  @override
  void saveProviderProfile(ProviderProfileData profile) {
    profiles.removeWhere((existing) => existing.id == profile.id);
    profiles.add(profile);
  }

  @override
  void deleteProviderProfile(String providerId) {
    profiles.removeWhere((profile) => profile.id == providerId);
  }

  @override
  List<ModelCatalogEntryData> listModelCatalogEntries() =>
      List.unmodifiable(catalog);

  @override
  void saveModelCatalogEntry(ModelCatalogEntryData entry) {
    catalog.removeWhere((existing) => existing.id == entry.id);
    catalog.add(entry);
  }

  @override
  void deleteModelCatalogEntry(String modelId) {
    catalog.removeWhere((entry) => entry.id == modelId);
  }

  @override
  void dispose() {}
}

const _verifiedPackage = ModelPackageValidationData(
  packageId: 'yixue.opus-en-zh.int8',
  displayName: '译学英中轻量模型',
  sourceLanguage: 'english',
  targetLanguage: 'chinese',
  baseModel: 'Helsinki-NLP/opus-mt-en-zh',
  license: 'Apache-2.0',
  verifiedFileCount: 6,
  totalBytes: 11,
);

class _MemorySecrets implements SecretBackend {
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<bool> containsKey(String key) async => values.containsKey(key);

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

void main() {
  testWidgets('model settings title reflects its full service scope', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1100, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ModelSettingsPage(
            coreFactory: _FakeCore.new,
            secretStore: ProviderSecretStore(_MemorySecrets()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('模型与服务'), findsOneWidget);
    expect(
      find.text('管理本地模型与 API，并为翻译、理解和语音能力选择使用路线。新配置默认停用，不会自动替换现有路线。'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'understanding usage navigation expands and scrolls a cached settings page',
    (tester) async {
      tester.view.physicalSize = const Size(900, 650);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final core = _FakeCore()
        ..profiles.add(
          const ProviderProfileData(
            id: 'understanding-api',
            displayName: '学习理解 API',
            kind: ProviderProfileKind.remoteApi,
            enabled: true,
            modelId: 'study-model',
            endpoint: 'https://api.example.com/v1',
            secretRef: 'study-api-key',
          ),
        );

      Widget page(int focusRequestId) => MaterialApp(
        home: Scaffold(
          body: ModelSettingsPage(
            coreFactory: () => core,
            secretStore: ProviderSecretStore(_MemorySecrets()),
            focusUnderstandingUsageRequestId: focusRequestId,
          ),
        ),
      );

      await tester.pumpWidget(page(0));
      await tester.pumpAndSettle();

      final usageButton = find.byKey(
        const ValueKey('provider-roles-understanding-api'),
      );
      expect(usageButton.hitTestable(), findsNothing);

      // Replace the widget configuration without removing its State, as
      // HomeShell does when the model settings page is already cached.
      await tester.pumpWidget(page(1));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();

      expect(usageButton.hitTestable(), findsOneWidget);
      final usageRect = tester.getRect(usageButton);
      expect(usageRect.top, greaterThanOrEqualTo(0));
      expect(
        usageRect.bottom,
        lessThanOrEqualTo(tester.view.physicalSize.height),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'daily setup shows the active API route and tests without switching',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final core = _FakeCore()
        ..profiles.addAll([
          const ProviderProfileData(
            id: 'active-api',
            displayName: '当前翻译 API',
            kind: ProviderProfileKind.remoteApi,
            enabled: true,
            modelId: 'translator-v2',
            endpoint: 'https://api.example.com/v1',
            secretRef: 'active-api-key',
            assignedRoles: {ModelRole.translation},
          ),
          const ProviderProfileData(
            id: 'other-local',
            displayName: '备用本地模型',
            kind: ProviderProfileKind.localModel,
            enabled: false,
            modelId: 'opus-mt-en-zh',
            modelPath: r'D:\models\opus-mt-en-zh',
          ),
        ]);
      ProviderProfileData? tested;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ModelSettingsPage(
              coreFactory: () => core,
              secretStore: ProviderSecretStore(_MemorySecrets()),
              connectivityTester: (profile) async => tested = profile,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('当前翻译：当前翻译 API'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('model-role-setup-guide')),
        findsOneWidget,
      );
      expect(find.textContaining('可在上方选择并设为翻译；先用短句试跑'), findsOneWidget);
      expect(find.textContaining('远程 API · 当前翻译 API'), findsOneWidget);
      expect(find.text('API 模型 · 可测试'), findsOneWidget);
      expect(find.textContaining('连接测试检查地址与密钥'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '选择模型并设为翻译'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('daily-translation-setup')),
          matching: find.byType(FilledButton),
        ),
        findsOneWidget,
      );
      expect(find.text('选择本地模型'), findsNothing);
      expect(find.text('选择 API 模型'), findsNothing);
      expect(find.widgetWithText(TextButton, '添加本地模型'), findsOneWidget);
      expect(find.widgetWithText(TextButton, '添加 API 模型'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('test-current-translation-provider')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('trial-current-translation-provider')),
        findsOneWidget,
      );
      expect(find.text('连接测试与模型试跑'), findsNothing);
      expect(
        tester
            .widget<ExpansionTile>(
              find.byKey(const ValueKey('local-models-category')),
            )
            .initiallyExpanded,
        isFalse,
      );
      expect(
        tester
            .widget<ExpansionTile>(
              find.byKey(const ValueKey('api-models-category')),
            )
            .initiallyExpanded,
        isFalse,
      );
      expect(find.textContaining('本地模型（'), findsOneWidget);
      expect(find.textContaining('API 服务（'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('test-current-translation-provider')),
      );
      await tester.pumpAndSettle();

      expect(tested?.id, 'active-api');
      expect(
        core.profiles
            .singleWhere((profile) => profile.id == 'active-api')
            .enabled,
        isTrue,
      );
      expect(
        core.profiles
            .singleWhere((profile) => profile.id == 'other-local')
            .enabled,
        isFalse,
      );
    },
  );

  testWidgets(
    'ambiguous enabled translation providers are shown and resolved explicitly',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final core = _FakeCore()
        ..profiles.addAll([
          const ProviderProfileData(
            id: 'remote-translation-a',
            displayName: '翻译 API 甲',
            kind: ProviderProfileKind.remoteApi,
            enabled: true,
            modelId: 'translator-a',
            endpoint: 'https://a.example.com/v1',
            assignedRoles: {ModelRole.translation},
          ),
          const ProviderProfileData(
            id: 'remote-translation-b',
            displayName: '翻译 API 乙',
            kind: ProviderProfileKind.remoteApi,
            enabled: true,
            modelId: 'translator-b',
            endpoint: 'https://b.example.com/v1',
            assignedRoles: {ModelRole.translation},
          ),
          const ProviderProfileData(
            id: 'local-translation',
            displayName: '旧本地翻译模型',
            kind: ProviderProfileKind.localModel,
            enabled: true,
            modelId: 'local-en-zh',
            modelPath: r'D:\models\local-en-zh',
            assignedRoles: {ModelRole.translation, ModelRole.understanding},
          ),
        ]);
      core.catalog.add(
        const ModelCatalogEntryData(
          id: 'catalog.old-local-translation',
          path: r'D:\models\local-en-zh',
          displayName: '旧本地翻译模型',
          family: 'yixue_translation',
          readiness: 'runtime_required',
          capabilities: ['translation', 'understanding'],
          assignedRoles: ['translation', 'understanding'],
          sourceLanguage: 'english',
          targetLanguage: 'chinese',
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ModelSettingsPage(
              coreFactory: () => core,
              secretStore: ProviderSecretStore(_MemorySecrets()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('translation-provider-conflict')),
        findsOneWidget,
      );
      expect(find.text('当前翻译：待选择唯一 Provider'), findsOneWidget);
      expect(find.text('翻译 API 甲（当前使用）'), findsNothing);

      await _expandRoleMap(tester);
      expect(find.text('3 个启用的 Provider 存在翻译冲突'), findsOneWidget);

      final resolveConflict = find.byKey(
        const ValueKey('resolve-translation-provider-conflict'),
      );
      await tester.ensureVisible(resolveConflict);
      await tester.tap(resolveConflict);
      await tester.pumpAndSettle();
      expect(find.text('选择翻译模型'), findsOneWidget);

      await tester.tap(find.text('翻译 API 乙').last);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('translation-provider-conflict')),
        findsNothing,
      );
      expect(find.text('当前翻译：翻译 API 乙'), findsOneWidget);
      expect(
        core.profiles
            .singleWhere((profile) => profile.id == 'remote-translation-a')
            .assignedRoles,
        isNot(contains(ModelRole.translation)),
      );
      expect(
        core.profiles
            .singleWhere((profile) => profile.id == 'remote-translation-b')
            .assignedRoles,
        contains(ModelRole.translation),
      );
      expect(
        core.profiles
            .singleWhere((profile) => profile.id == 'local-translation')
            .assignedRoles,
        {ModelRole.understanding},
      );
      expect(core.catalog.single.assignedRoles, ['understanding']);
    },
  );

  testWidgets(
    'mixed local and API translation conflict has no current model marker',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final core = _FakeCore()
        ..profiles.addAll([
          const ProviderProfileData(
            id: 'local-conflict',
            displayName: '本地混合冲突模型',
            kind: ProviderProfileKind.localModel,
            enabled: true,
            modelId: 'opus-mt-en-zh',
            modelPath: r'D:\models\opus-mt-en-zh',
            assignedRoles: {ModelRole.translation},
          ),
          const ProviderProfileData(
            id: 'api-conflict',
            displayName: '远程混合冲突 API',
            kind: ProviderProfileKind.remoteApi,
            enabled: true,
            modelId: 'translator-v2',
            endpoint: 'https://api.example.com/v1',
            assignedRoles: {ModelRole.translation},
          ),
        ]);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ModelSettingsPage(
              coreFactory: () => core,
              secretStore: ProviderSecretStore(_MemorySecrets()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('translation-provider-conflict')),
        findsOneWidget,
      );
      expect(find.text('当前翻译：待选择唯一 Provider'), findsOneWidget);

      await _expandConfiguredModels(tester);
      expect(find.text('当前翻译'), findsNothing);
      expect(find.text('设为翻译'), findsNWidgets(2));
    },
  );

  testWidgets(
    'disabled translation assignments do not mask an enabled loopback API',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final core = _FakeCore()
        ..profiles.addAll([
          const ProviderProfileData(
            id: 'disabled-local',
            displayName: '已停用本地模型',
            kind: ProviderProfileKind.localModel,
            enabled: false,
            modelId: 'opus-mt-en-zh',
            modelPath: r'D:\models\opus-mt-en-zh',
            assignedRoles: {ModelRole.translation},
          ),
          const ProviderProfileData(
            id: 'loopback-api',
            displayName: '本机翻译服务',
            kind: ProviderProfileKind.remoteApi,
            enabled: true,
            modelId: 'qwen-local',
            endpoint: 'http://127.0.0.1:11434/v1',
            assignedRoles: {ModelRole.translation},
          ),
        ]);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ModelSettingsPage(
              coreFactory: () => core,
              secretStore: ProviderSecretStore(_MemorySecrets()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('当前翻译：本机翻译服务'), findsOneWidget);
      expect(find.textContaining('本机 API · 本机翻译服务'), findsOneWidget);
      expect(find.textContaining('远程 API · 本机翻译服务'), findsNothing);
      expect(
        find.byKey(const ValueKey('translation-provider-conflict')),
        findsNothing,
      );

      await _expandRoleMap(tester);
      expect(find.text('本机翻译服务（当前使用）'), findsOneWidget);
    },
  );

  testWidgets('switch translation method selects a local provider explicitly', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final core = _FakeCore()
      ..profiles.addAll([
        const ProviderProfileData(
          id: 'active-api',
          displayName: '当前 API',
          kind: ProviderProfileKind.remoteApi,
          enabled: true,
          modelId: 'translator-v2',
          endpoint: 'https://api.example.com/v1',
          assignedRoles: {ModelRole.translation},
        ),
        const ProviderProfileData(
          id: 'next-local',
          displayName: '新本地模型',
          kind: ProviderProfileKind.localModel,
          enabled: false,
          modelId: 'opus-mt-en-zh',
          modelPath: r'D:\models\opus-mt-en-zh',
        ),
      ]);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ModelSettingsPage(
            coreFactory: () => core,
            secretStore: ProviderSecretStore(_MemorySecrets()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('choose-translation-provider')));
    await tester.pumpAndSettle();

    expect(find.text('选择翻译模型'), findsOneWidget);
    expect(find.text('新本地模型'), findsOneWidget);
    expect(find.text('当前 API'), findsOneWidget);
    expect(find.widgetWithText(TextButton, '设为翻译'), findsOneWidget);
    expect(
      core.profiles
          .singleWhere((profile) => profile.id == 'active-api')
          .enabled,
      isTrue,
    );
    expect(
      core.profiles
          .singleWhere((profile) => profile.id == 'next-local')
          .enabled,
      isFalse,
    );

    await tester.tap(find.widgetWithText(TextButton, '设为翻译'));
    await tester.pumpAndSettle();

    expect(
      core.profiles
          .singleWhere((profile) => profile.id == 'active-api')
          .enabled,
      isFalse,
    );
    final selected = core.profiles.singleWhere(
      (profile) => profile.id == 'next-local',
    );
    expect(selected.enabled, isTrue);
    expect(selected.assignedRoles, contains(ModelRole.translation));
    expect(find.text('当前翻译：新本地模型'), findsOneWidget);
  });

  testWidgets('enabled models remain selectable as the translation service', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final core = _FakeCore();
    core.profiles.add(
      const ProviderProfileData(
        id: 'local-general-model',
        displayName: '本机综合模型',
        kind: ProviderProfileKind.localModel,
        enabled: true,
        modelId: 'opus-mt-en-zh',
        modelPath: r'D:\models\opus-mt-en-zh',
        assignedRoles: {ModelRole.understanding},
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ModelSettingsPage(
            coreFactory: () => core,
            secretStore: ProviderSecretStore(_MemorySecrets()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('当前翻译：译学随包英汉模型'), findsOneWidget);
    await _expandConfiguredModels(tester);
    final setAsTranslation = find.widgetWithText(TextButton, '设为翻译');
    expect(setAsTranslation, findsOneWidget);
    await tester.tap(setAsTranslation);
    await tester.pumpAndSettle();

    expect(find.text('当前翻译：本机综合模型'), findsOneWidget);
    expect(core.profiles.single.assignedRoles, contains(ModelRole.translation));
    expect(
      core.profiles.single.assignedRoles,
      contains(ModelRole.understanding),
    );
  });

  testWidgets('current translation model can be changed from the overview', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final core = _FakeCore()
      ..profiles.add(
        const ProviderProfileData(
          id: 'translation-api',
          displayName: '快速翻译 API',
          kind: ProviderProfileKind.remoteApi,
          enabled: false,
          modelId: 'translator-v1',
          endpoint: 'https://api.example.com/v1',
          secretRef: 'translation-api-secret',
        ),
      );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ModelSettingsPage(
            coreFactory: () => core,
            secretStore: ProviderSecretStore(_MemorySecrets()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('choose-translation-provider')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('快速翻译 API'),
      ),
    );
    await tester.pumpAndSettle();

    final profile = core.profiles.single;
    expect(profile.enabled, isTrue);
    expect(profile.assignedRoles, contains(ModelRole.translation));
    expect(find.text('当前翻译：快速翻译 API'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('browses for a local model folder instead of requiring typing', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final core = _FakeCore();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ModelSettingsPage(
            coreFactory: () => core,
            secretStore: ProviderSecretStore(_MemorySecrets()),
            directoryPicker: () async => r'D:\models\opus-mt-en-zh',
            modelValidator: (_) => _verifiedPackage,
          ),
        ),
      ),
    );

    await tester.tap(find.text('添加本地模型'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('浏览'));
    await tester.pumpAndSettle();

    final field = tester.widget<TextFormField>(
      find.widgetWithText(TextFormField, '模型文件夹'),
    );
    expect(field.controller?.text, r'D:\models\opus-mt-en-zh');
  });

  testWidgets('shows both bundled English-Chinese model directions on load', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final core = _FakeCore();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ModelSettingsPage(
            coreFactory: () => core,
            secretStore: ProviderSecretStore(_MemorySecrets()),
            bundledModelRootPath: r'D:\译学\bundled-models',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _expandConfiguredModels(tester);
    await _expandTranslationRoutes(tester);
    expect(find.text('随包英汉模型'), findsOneWidget);
    final routes = find.byKey(const ValueKey('translation-direction-routes'));
    expect(
      find.descendant(of: routes, matching: find.textContaining('译学英中轻量模型')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: routes, matching: find.textContaining('译学中英轻量模型')),
      findsOneWidget,
    );
    expect(find.textContaining('随包默认'), findsWidgets);
    expect(core.catalog, hasLength(2));
  });

  testWidgets('keeps add-model actions usable in the first viewport', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final core = _FakeCore();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ModelSettingsPage(
            coreFactory: () => core,
            secretStore: ProviderSecretStore(_MemorySecrets()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final addApi = find.byKey(const ValueKey('add-api-translation-provider'));
    expect(tester.getCenter(addApi).dy, lessThan(900));
    await tester.tap(addApi);
    await tester.pumpAndSettle();
    expect(find.text('添加 API 模型'), findsNWidgets(2));
  });

  testWidgets(
    'keeps the primary model action reachable at minimum window size and enlarged text',
    (tester) async {
      tester.view.physicalSize = const Size(960, 620);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final core = _FakeCore();

      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
            child: Scaffold(
              body: ModelSettingsPage(
                coreFactory: () => core,
                secretStore: ProviderSecretStore(_MemorySecrets()),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final addApi = find.byKey(const ValueKey('add-api-translation-provider'));
      expect(addApi, findsOneWidget);
      await tester.tap(addApi);
      await tester.pumpAndSettle();
      expect(find.text('添加 API 模型'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('discovers and imports a model from a user selected location', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final core = _FakeCore();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ModelSettingsPage(
            coreFactory: () => core,
            secretStore: ProviderSecretStore(_MemorySecrets()),
            directoryPicker: () async => r'D:\models',
            modelDiscovery: (_) async => <String>[r'D:\models\opus-mt-en-zh'],
            modelValidator: (_) => _verifiedPackage,
          ),
        ),
      ),
    );

    await _tapModelDiscoveryAction(tester, '搜索指定位置');

    await _expandConfiguredModels(tester);
    expect(find.text('译学英中轻量模型'), findsOneWidget);
    expect(core.profiles.single.modelPath, r'D:\models\opus-mt-en-zh');
    expect(core.catalog.single.assignedRoles, ['translation']);
  });

  testWidgets('one-click scan shows Qwen in the model overview without error', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final core = _FakeCore();
    const qwen = ModelCandidate(
      path: r'D:\models\Qwen3-4B',
      displayName: 'Qwen3-4B',
      family: ModelFamily.qwen,
      readiness: ModelReadiness.runtimeRequired,
      capabilities: {ModelCapability.generalText, ModelCapability.translation},
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ModelSettingsPage(
            coreFactory: () => core,
            secretStore: ProviderSecretStore(_MemorySecrets()),
            driveRootsProvider: () async => <String>[r'D:\'],
            modelCatalogDiscovery: (_) async => const <ModelCandidate>[qwen],
          ),
        ),
      ),
    );

    await _tapModelDiscoveryAction(tester, '搜索本机磁盘');
    await _expandDiscoveredModels(tester);

    expect(find.text('模型总览'), findsOneWidget);
    expect(find.text('Qwen3-4B'), findsOneWidget);
    expect(find.textContaining('已发现 · 需接入运行内核'), findsOneWidget);
    expect(find.text('配置兼容接口'), findsOneWidget);
    expect(find.textContaining('安装包不会自动安装或启动 Ollama'), findsOneWidget);
    expect(find.textContaining(r'D:\models\Qwen3-4B'), findsOneWidget);
    expect(core.catalog, hasLength(1));
  });

  testWidgets(
    'saving a discovered compatible endpoint does not activate it automatically',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final core = _FakeCore();
      const qwen = ModelCandidate(
        path: r'D:\models\Qwen3-4B',
        displayName: 'Qwen3-4B',
        family: ModelFamily.qwen,
        readiness: ModelReadiness.runtimeRequired,
        capabilities: {
          ModelCapability.generalText,
          ModelCapability.translation,
        },
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ModelSettingsPage(
              coreFactory: () => core,
              secretStore: ProviderSecretStore(_MemorySecrets()),
              driveRootsProvider: () async => <String>[r'D:\'],
              modelCatalogDiscovery: (_) async => const <ModelCandidate>[qwen],
            ),
          ),
        ),
      );
      await _tapModelDiscoveryAction(tester, '搜索本机磁盘');
      await _expandDiscoveredModels(tester);
      await tester.tap(find.text('配置兼容接口'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存并保持停用'));
      await tester.pumpAndSettle();

      expect(core.profiles, hasLength(1));
      expect(core.profiles.single.enabled, isFalse);
      expect(core.profiles.single.assignedRoles, isEmpty);
    },
  );

  testWidgets('discovered models survive rebuilding the settings page', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final core = _FakeCore()
      ..catalog.add(
        const ModelCatalogEntryData(
          id: 'catalog.qwen.1234',
          path: r'D:\models\Qwen3.5-4B',
          displayName: 'Qwen3.5-4B',
          family: 'qwen',
          readiness: 'runtime_required',
          capabilities: ['general_text', 'translation', 'summarization'],
          assignedRoles: ['understanding'],
        ),
      );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ModelSettingsPage(
            coreFactory: () => core,
            secretStore: ProviderSecretStore(_MemorySecrets()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _expandDiscoveredModels(tester);
    expect(find.text('Qwen3.5-4B'), findsOneWidget);
    expect(find.textContaining('理解与总结'), findsWidgets);
  });

  testWidgets('assigns a discovered model to a supported role and saves it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final core = _FakeCore();
    const qwen = ModelCandidate(
      path: r'D:\models\Qwen3.5-4B',
      displayName: 'Qwen3.5-4B',
      family: ModelFamily.qwen,
      readiness: ModelReadiness.runtimeRequired,
      capabilities: {
        ModelCapability.translation,
        ModelCapability.summarization,
      },
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ModelSettingsPage(
            coreFactory: () => core,
            secretStore: ProviderSecretStore(_MemorySecrets()),
            driveRootsProvider: () async => <String>[r'D:\'],
            modelCatalogDiscovery: (_) async => const [qwen],
          ),
        ),
      ),
    );
    await _tapModelDiscoveryAction(tester, '搜索本机磁盘');
    await _expandDiscoveredModels(tester);
    final setUsage = find.text('设置用途');
    await tester.ensureVisible(setUsage);
    await tester.tap(setUsage);
    await tester.pumpAndSettle();
    final translationRole = find.text('翻译').last;
    await tester.ensureVisible(translationRole);
    await tester.tap(translationRole);
    await tester.pumpAndSettle();

    expect(core.catalog.single.assignedRoles, ['translation']);
    expect(find.textContaining('已指定候选：翻译'), findsOneWidget);
  });

  testWidgets('selecting a Qwen folder catalogs it instead of validating it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final core = _FakeCore();
    var validationCalls = 0;
    const qwen = ModelCandidate(
      path: r'D:\models\Qwen2.5-7B',
      displayName: 'Qwen2.5-7B',
      family: ModelFamily.qwen,
      readiness: ModelReadiness.runtimeRequired,
      capabilities: {ModelCapability.generalText, ModelCapability.translation},
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ModelSettingsPage(
            coreFactory: () => core,
            secretStore: ProviderSecretStore(_MemorySecrets()),
            directoryPicker: () async => qwen.path,
            modelFolderInspector: (_) async => qwen,
            modelValidator: (_) {
              validationCalls += 1;
              return _verifiedPackage;
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('添加本地模型'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('浏览'));
    await tester.tap(find.text('识别并添加'));
    await tester.pumpAndSettle();

    expect(validationCalls, 0);
    await _expandDiscoveredModels(tester);
    expect(find.text('Qwen2.5-7B'), findsOneWidget);
    expect(find.textContaining('千问模型已经找到'), findsOneWidget);
  });

  testWidgets(
    'model details explain why an unconfigured Qwen needs an endpoint',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final core = _FakeCore();
      const qwen = ModelCandidate(
        path: r'D:\models\Qwen3',
        displayName: 'Qwen3',
        family: ModelFamily.qwen,
        readiness: ModelReadiness.runtimeRequired,
        capabilities: {ModelCapability.generalText},
        pathAvailable: true,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ModelSettingsPage(
              coreFactory: () => core,
              secretStore: ProviderSecretStore(_MemorySecrets()),
              driveRootsProvider: () async => <String>[r'D:\'],
              modelCatalogDiscovery: (_) async => const <ModelCandidate>[qwen],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _tapModelDiscoveryAction(tester, '搜索本机磁盘');
      await _expandDiscoveredModels(tester);
      final modelDetails = find.byTooltip('查看模型详情');
      await tester.ensureVisible(modelDetails);
      await tester.tap(modelDetails);
      await tester.pumpAndSettle();

      expect(find.text('兼容性：需要已有兼容接口'), findsOneWidget);
      expect(find.textContaining('Ollama'), findsOneWidget);
      expect(find.textContaining('不会直接执行千问权重'), findsOneWidget);
    },
  );

  testWidgets('shows progress and locks local actions during validation', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final core = _FakeCore();
    final validation = Completer<ModelPackageValidationData>();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ModelSettingsPage(
            coreFactory: () => core,
            secretStore: ProviderSecretStore(_MemorySecrets()),
            modelValidator: (_) => validation.future,
          ),
        ),
      ),
    );
    await tester.tap(find.text('添加本地模型'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, '模型文件夹'),
      r'D:\models\opus-mt-en-zh',
    );
    await tester.tap(find.text('识别并添加'));
    await tester.pump();

    expect(find.text('正在校验模型完整性…'), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '添加本地模型'))
          .onPressed,
      isNull,
    );

    validation.complete(_verifiedPackage);
    await tester.pumpAndSettle();
    expect(find.text('正在校验模型完整性…'), findsNothing);
  });

  testWidgets('adds and enables a verified local model package', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final core = _FakeCore();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ModelSettingsPage(
            coreFactory: () => core,
            secretStore: ProviderSecretStore(_MemorySecrets()),
            modelValidator: (_) => _verifiedPackage,
          ),
        ),
      ),
    );
    await tester.tap(find.text('添加本地模型'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextFormField, '模型文件夹'),
      r'D:\models\opus-mt-en-zh',
    );
    await tester.tap(find.text('识别并添加'));
    await tester.pumpAndSettle();

    await _expandConfiguredModels(tester);
    expect(find.text('译学英中轻量模型'), findsOneWidget);
    expect(find.text('Helsinki-NLP/opus-mt-en-zh  ·  已校验'), findsOneWidget);
    expect(core.profiles.single.kind, ProviderProfileKind.localModel);
    expect(core.profiles.single.enabled, isTrue);
  });

  testWidgets('rejects a local model that fails package validation', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final core = _FakeCore();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ModelSettingsPage(
            coreFactory: () => core,
            secretStore: ProviderSecretStore(_MemorySecrets()),
            modelValidator: (_) => throw const CoreBridgeException(
              'model_package_invalid',
              '模型包校验失败',
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('添加本地模型'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, '模型文件夹'),
      r'D:\models\invalid',
    );
    await tester.tap(find.text('识别并添加'));
    await tester.pumpAndSettle();

    expect(find.textContaining('模型包校验失败'), findsOneWidget);
    expect(core.profiles, isEmpty);
  });

  testWidgets(
    'API setup hides optional sections and explains remote text delivery',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ModelSettingsPage(
              coreFactory: _FakeCore.new,
              secretStore: ProviderSecretStore(_MemorySecrets()),
            ),
          ),
        ),
      );
      await tester.tap(find.text('添加 API 模型'));
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<ExpansionTile>(
              find.byKey(const ValueKey('provider-presets')),
            )
            .initiallyExpanded,
        isFalse,
      );
      expect(
        tester
            .widget<ExpansionTile>(
              find.byKey(const ValueKey('provider-advanced-options')),
            )
            .initiallyExpanded,
        isFalse,
      );
      expect(find.widgetWithText(TextFormField, '配置 ID'), findsNothing);
      expect(
        find.byKey(const ValueKey('remote-service-disclosure')),
        findsOneWidget,
      );
      expect(find.textContaining('翻译文本会发送给服务商'), findsOneWidget);

      await tester.enterText(
        find.widgetWithText(TextFormField, 'API 地址'),
        'http://127.0.0.1:11434/v1',
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey('remote-service-disclosure')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('local-compatible-guidance')),
        findsOneWidget,
      );
    },
  );

  testWidgets('discloses remote translation before the route is selected', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final core = _FakeCore()
      ..profiles.addAll([
        const ProviderProfileData(
          id: 'local-current',
          displayName: '本机模型',
          kind: ProviderProfileKind.localModel,
          enabled: true,
          modelId: 'local-translator',
          modelPath: r'D:\models\local-translator',
          assignedRoles: {ModelRole.translation},
        ),
        const ProviderProfileData(
          id: 'remote-candidate',
          displayName: '远程服务',
          kind: ProviderProfileKind.remoteApi,
          enabled: false,
          modelId: 'remote-translator',
          endpoint: 'https://api.example.com/v1',
        ),
      ]);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ModelSettingsPage(
            coreFactory: () => core,
            secretStore: ProviderSecretStore(_MemorySecrets()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('choose-translation-provider')));
    await tester.pumpAndSettle();

    expect(find.text('使用远程 API 时，翻译原文会发送给所选服务；失败时不会自动切换。'), findsOneWidget);
    expect(
      core.profiles
          .firstWhere((profile) => profile.id == 'remote-candidate')
          .enabled,
      isFalse,
    );
    expect(
      core.profiles
          .firstWhere((profile) => profile.id == 'remote-candidate')
          .assignedRoles,
      isEmpty,
    );

    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('adds an API model without displaying its secret', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final core = _FakeCore();
    final secrets = _MemorySecrets();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ModelSettingsPage(
            coreFactory: () => core,
            secretStore: ProviderSecretStore(secrets),
          ),
        ),
      ),
    );
    await tester.tap(find.text('添加 API 模型'));
    await tester.pumpAndSettle();

    await _expandRemoteProviderAdvanced(tester);

    await tester.enterText(
      find.widgetWithText(TextFormField, '显示名称'),
      '我的翻译模型',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, '配置 ID'),
      'my-api',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, '模型 ID'),
      'translator-v1',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'API 密钥'),
      'private-test-value',
    );
    await tester.tap(find.text('保存并保持停用'));
    await tester.pumpAndSettle();

    await _expandConfiguredModels(tester);
    expect(find.text('我的翻译模型'), findsOneWidget);
    expect(find.text('translator-v1  ·  密钥已保护'), findsOneWidget);
    expect(find.text('private-test-value'), findsNothing);
    expect(core.profiles.single.secretRef, 'yixue.provider.my-api.api-key');
    expect(secrets.values.values.single, 'private-test-value');
    expect(core.profiles.single.enabled, isFalse);
    expect(core.profiles.single.assignedRoles, isEmpty);
  });

  testWidgets('API model ID is generated when advanced settings stay closed', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final core = _FakeCore();
    final secrets = _MemorySecrets();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ModelSettingsPage(
            coreFactory: () => core,
            secretStore: ProviderSecretStore(secrets),
          ),
        ),
      ),
    );
    await tester.tap(find.text('添加 API 模型'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextFormField, '显示名称'),
      'My Translation',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, '模型 ID'),
      'translator-v1',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'API 密钥'),
      'private-test-value',
    );
    await tester.tap(find.text('保存并保持停用'));
    await tester.pumpAndSettle();

    final profile = core.profiles.single;
    expect(profile.id, matches(RegExp(r'^api-my-translation-[a-z0-9]+$')));
    expect(profile.secretRef, 'yixue.provider.${profile.id}.api-key');
    expect(secrets.values.values.single, 'private-test-value');
    expect(profile.enabled, isFalse);
    expect(profile.assignedRoles, isEmpty);
    expect(find.text('当前翻译：译学随包英汉模型'), findsOneWidget);
  });

  testWidgets('adds a loopback compatible model without an API key', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final core = _FakeCore();
    final secrets = _MemorySecrets();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ModelSettingsPage(
            coreFactory: () => core,
            secretStore: ProviderSecretStore(secrets),
          ),
        ),
      ),
    );
    await tester.tap(find.text('添加 API 模型'));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextFormField, '显示名称'), '本地千问');
    await tester.enterText(
      find.widgetWithText(TextFormField, 'API 地址'),
      'http://127.0.0.1:11435/v1',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, '模型 ID'),
      'qwen3.5:4b',
    );
    expect(
      find.byKey(const ValueKey('remote-service-disclosure')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('local-compatible-guidance')),
      findsOneWidget,
    );
    await tester.tap(find.text('保存并保持停用'));
    await tester.pumpAndSettle();

    expect(core.profiles.single.secretRef, isNull);
    await _expandConfiguredModels(tester);
    expect(find.text('qwen3.5:4b  ·  本地接口'), findsOneWidget);
    expect(core.profiles.single.enabled, isFalse);
    expect(core.profiles.single.assignedRoles, isEmpty);
    expect(secrets.values, isEmpty);
  });

  testWidgets('prefills a local Ollama provider from the friendly preset', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final core = _FakeCore();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ModelSettingsPage(
            coreFactory: () => core,
            secretStore: ProviderSecretStore(_MemorySecrets()),
          ),
        ),
      ),
    );
    await tester.tap(find.text('添加 API 模型'));
    await tester.pumpAndSettle();
    await _expandRemoteProviderPresets(tester);
    await tester.tap(find.byKey(const ValueKey('use-ollama-local')));
    await tester.pump();
    expect(find.textContaining('2,048'), findsOneWidget);
    expect(find.textContaining('64'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextFormField, '模型 ID'),
      'qwen3.5:4b',
    );
    await tester.tap(find.text('保存并保持停用'));
    await tester.pumpAndSettle();

    expect(core.profiles.single.displayName, '本地 Ollama');
    expect(core.profiles.single.endpoint, 'http://127.0.0.1:11434/api');
    expect(core.profiles.single.secretRef, isNull);
  });

  testWidgets(
    'prefills the official DeepSeek API provider from the friendly preset',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final core = _FakeCore();
      final secrets = _MemorySecrets();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ModelSettingsPage(
              coreFactory: () => core,
              secretStore: ProviderSecretStore(secrets),
            ),
          ),
        ),
      );
      await tester.tap(find.text('添加 API 模型'));
      await tester.pumpAndSettle();
      await _expandRemoteProviderPresets(tester);
      await tester.tap(find.byKey(const ValueKey('use-deepseek-api')));
      await tester.pump();

      expect(
        tester
            .widget<TextFormField>(find.widgetWithText(TextFormField, 'API 地址'))
            .controller
            ?.text,
        'https://api.deepseek.com',
      );
      expect(
        tester
            .widget<TextFormField>(find.widgetWithText(TextFormField, '模型 ID'))
            .controller
            ?.text,
        'deepseek-flash',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'API 密钥'),
        'deepseek-test-key',
      );
      await tester.tap(find.text('保存并保持停用'));
      await tester.pumpAndSettle();

      expect(core.profiles.single.displayName, 'DeepSeek API');
      expect(core.profiles.single.endpoint, 'https://api.deepseek.com');
      expect(core.profiles.single.modelId, 'deepseek-flash');
      expect(
        core.profiles.single.secretRef,
        'yixue.provider.deepseek-api.api-key',
      );
      expect(secrets.values.values.single, 'deepseek-test-key');
      expect(find.text('deepseek-test-key'), findsNothing);
    },
  );

  testWidgets(
    'prefills a generic OpenAI-compatible provider without choosing a vendor',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final core = _FakeCore();
      final secrets = _MemorySecrets();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ModelSettingsPage(
              coreFactory: () => core,
              secretStore: ProviderSecretStore(secrets),
            ),
          ),
        ),
      );
      await tester.tap(find.text('添加 API 模型'));
      await tester.pumpAndSettle();
      await _expandRemoteProviderPresets(tester);
      await tester.tap(find.byKey(const ValueKey('use-openai-compatible')));
      await tester.pump();

      expect(
        tester
            .widget<TextFormField>(find.widgetWithText(TextFormField, 'API 地址'))
            .controller
            ?.text,
        'https://api.openai.com/v1',
      );
      expect(
        tester
            .widget<TextFormField>(find.widgetWithText(TextFormField, '模型 ID'))
            .controller
            ?.text,
        isEmpty,
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, '模型 ID'),
        'vendor-translation-model',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'API 密钥'),
        'vendor-test-key',
      );
      await tester.tap(find.text('保存并保持停用'));
      await tester.pumpAndSettle();

      expect(core.profiles.single.displayName, 'OpenAI 兼容接口');
      expect(core.profiles.single.endpoint, 'https://api.openai.com/v1');
      expect(core.profiles.single.modelId, 'vendor-translation-model');
      expect(
        core.profiles.single.secretRef,
        'yixue.provider.openai-compatible.api-key',
      );
      expect(secrets.values.values.single, 'vendor-test-key');
    },
  );

  testWidgets('selects one API provider as the current translation model', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final core = _FakeCore()
      ..profiles.addAll([
        const ProviderProfileData(
          id: 'api-a',
          displayName: '翻译 API A',
          kind: ProviderProfileKind.remoteApi,
          enabled: true,
          modelId: 'translator-a',
          endpoint: 'https://a.example/v1',
          secretRef: 'secret-a',
        ),
        const ProviderProfileData(
          id: 'api-b',
          displayName: '翻译 API B',
          kind: ProviderProfileKind.remoteApi,
          enabled: false,
          modelId: 'translator-b',
          endpoint: 'https://b.example/v1',
          secretRef: 'secret-b',
        ),
      ]);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ModelSettingsPage(
            coreFactory: () => core,
            secretStore: ProviderSecretStore(_MemorySecrets()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _expandConfiguredModels(tester);
    final selectApi = find.widgetWithText(TextButton, '设为翻译').last;
    await tester.ensureVisible(selectApi);
    await tester.tap(selectApi);
    await tester.pumpAndSettle();

    expect(
      core.profiles.firstWhere((profile) => profile.id == 'api-a').enabled,
      isFalse,
    );
    expect(
      core.profiles.firstWhere((profile) => profile.id == 'api-b').enabled,
      isTrue,
    );
    expect(find.text('当前翻译'), findsOneWidget);
  });

  testWidgets('selecting API disables an enabled local translation provider', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final core = _FakeCore()
      ..profiles.addAll([
        const ProviderProfileData(
          id: 'local-current',
          displayName: '当前本地翻译',
          kind: ProviderProfileKind.localModel,
          enabled: true,
          modelId: 'yixue.opus-en-zh.int8',
          modelPath: r'D:\models\yixue.opus-en-zh.int8',
          assignedRoles: {ModelRole.translation},
        ),
        const ProviderProfileData(
          id: 'api-next',
          displayName: '备用 API',
          kind: ProviderProfileKind.remoteApi,
          enabled: false,
          modelId: 'translator-v2',
          endpoint: 'https://api.example.com/v1',
          secretRef: 'secret-api-next',
        ),
      ])
      ..catalog.addAll([
        const ModelCatalogEntryData(
          id: 'catalog.local-current',
          path: r'D:\models\yixue.opus-en-zh.int8',
          displayName: '当前本地翻译',
          family: 'transformers',
          readiness: 'runtime_required',
          capabilities: ['translation'],
          assignedRoles: ['translation'],
          sourceLanguage: 'english',
          targetLanguage: 'chinese',
        ),
        const ModelCatalogEntryData(
          id: 'catalog.unconfigured-candidate',
          path: r'D:\models\ja-ko-candidate',
          displayName: '未接入候选模型',
          family: 'transformers',
          readiness: 'runtime_required',
          capabilities: ['translation'],
          assignedRoles: ['translation'],
          sourceLanguage: 'japanese',
          targetLanguage: 'korean',
        ),
      ]);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ModelSettingsPage(
            coreFactory: () => core,
            secretStore: ProviderSecretStore(_MemorySecrets()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _expandConfiguredModels(tester);
    final selectApi = find.descendant(
      of: find.byKey(const ValueKey('api-next')),
      matching: find.widgetWithText(TextButton, '设为翻译'),
    );
    await tester.ensureVisible(selectApi);
    await tester.tap(selectApi);
    await tester.pumpAndSettle();

    expect(
      core.profiles
          .firstWhere((profile) => profile.id == 'local-current')
          .enabled,
      isFalse,
    );
    expect(
      core.profiles.firstWhere((profile) => profile.id == 'api-next').enabled,
      isTrue,
    );
    expect(
      core.profiles
          .firstWhere((profile) => profile.id == 'local-current')
          .assignedRoles,
      isEmpty,
    );
    expect(
      core.profiles
          .firstWhere((profile) => profile.id == 'api-next')
          .assignedRoles,
      contains(ModelRole.translation),
    );
    expect(
      core.catalog
          .firstWhere((entry) => entry.id == 'catalog.local-current')
          .assignedRoles,
      isNot(contains('translation')),
    );
    expect(
      core.catalog
          .firstWhere((entry) => entry.id == 'catalog.unconfigured-candidate')
          .assignedRoles,
      contains('translation'),
    );
  });

  testWidgets('selecting translation keeps an enabled understanding provider', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final core = _FakeCore()
      ..profiles.addAll([
        const ProviderProfileData(
          id: 'translation-provider',
          displayName: '翻译模型',
          kind: ProviderProfileKind.remoteApi,
          enabled: false,
          modelId: 'translator',
          endpoint: 'https://translator.example/v1',
          assignedRoles: {ModelRole.translation},
        ),
        const ProviderProfileData(
          id: 'understanding-provider',
          displayName: '理解模型',
          kind: ProviderProfileKind.remoteApi,
          enabled: true,
          modelId: 'summarizer',
          endpoint: 'https://summary.example/v1',
          assignedRoles: {ModelRole.understanding},
        ),
      ]);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ModelSettingsPage(
            coreFactory: () => core,
            secretStore: ProviderSecretStore(_MemorySecrets()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _expandConfiguredModels(tester);
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('translation-provider')),
        matching: find.widgetWithText(TextButton, '设为翻译'),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      core.profiles
          .singleWhere((profile) => profile.id == 'translation-provider')
          .enabled,
      isTrue,
    );
    final understanding = core.profiles.singleWhere(
      (profile) => profile.id == 'understanding-provider',
    );
    expect(understanding.enabled, isTrue);
    expect(understanding.assignedRoles, {ModelRole.understanding});
  });

  testWidgets('role map identifies the configured translation provider', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final core = _FakeCore()
      ..profiles.add(
        const ProviderProfileData(
          id: 'local-current',
          displayName: '当前本地翻译',
          kind: ProviderProfileKind.localModel,
          enabled: true,
          modelId: 'custom-model',
          modelPath: r'D:\models\custom-en-zh',
        ),
      )
      ..catalog.add(
        const ModelCatalogEntryData(
          id: 'catalog.current',
          path: r'D:\models\custom-en-zh',
          displayName: '自定义英中模型',
          family: 'transformers',
          readiness: 'runtime_required',
          capabilities: ['translation'],
          assignedRoles: ['translation'],
          sourceLanguage: 'english',
          targetLanguage: 'chinese',
        ),
      );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ModelSettingsPage(
            coreFactory: () => core,
            secretStore: ProviderSecretStore(_MemorySecrets()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('当前翻译：本地模型按语种匹配'), findsOneWidget);
    await _expandConfiguredModels(tester);
    expect(find.text('当前翻译'), findsNothing);
    expect(find.text('按语种匹配'), findsNWidgets(2));

    await _expandRoleMap(tester);
    expect(find.text('当前本地翻译（按语种匹配）'), findsOneWidget);
  });

  testWidgets(
    'shows the actual local model beside each translation direction',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final core = _FakeCore()
        ..profiles.addAll([
          const ProviderProfileData(
            id: 'en-zh-route',
            displayName: '英译中本地模型',
            kind: ProviderProfileKind.localModel,
            enabled: true,
            modelId: 'opus-en-zh',
            modelPath: r'D:\models\en-zh',
            assignedRoles: {ModelRole.translation},
          ),
          const ProviderProfileData(
            id: 'zh-en-route',
            displayName: '中译英本地模型',
            kind: ProviderProfileKind.localModel,
            enabled: true,
            modelId: 'opus-zh-en',
            modelPath: r'D:\models\zh-en',
            assignedRoles: {ModelRole.translation},
          ),
          const ProviderProfileData(
            id: 'ja-ko-route',
            displayName: '日译韩本地模型',
            kind: ProviderProfileKind.localModel,
            enabled: true,
            modelId: 'opus-ja-ko',
            modelPath: r'D:\models\ja-ko',
            assignedRoles: {ModelRole.translation},
          ),
          const ProviderProfileData(
            id: 'ko-ja-route',
            displayName: '韩译日本地模型',
            kind: ProviderProfileKind.localModel,
            enabled: true,
            modelId: 'opus-ko-ja',
            modelPath: r'D:\models\ko-ja',
            assignedRoles: {ModelRole.translation},
          ),
        ])
        ..catalog.addAll([
          const ModelCatalogEntryData(
            id: 'catalog.en-zh',
            path: r'D:\models\en-zh',
            displayName: 'English to Chinese model',
            family: 'transformers',
            readiness: 'runtime_required',
            capabilities: ['translation'],
            assignedRoles: ['translation'],
            sourceLanguage: 'eng',
            targetLanguage: 'cmn-Hans-CN',
          ),
          const ModelCatalogEntryData(
            id: 'catalog.zh-en',
            path: r'D:\models\zh-en',
            displayName: 'Chinese to English model',
            family: 'transformers',
            readiness: 'runtime_required',
            capabilities: ['translation'],
            assignedRoles: ['translation'],
            sourceLanguage: 'zho-TW',
            targetLanguage: 'eng',
          ),
          const ModelCatalogEntryData(
            id: 'catalog.ja-ko',
            path: r'D:\models\ja-ko',
            displayName: 'Japanese to Korean model',
            family: 'transformers',
            readiness: 'runtime_required',
            capabilities: ['translation'],
            assignedRoles: ['translation'],
            sourceLanguage: 'jpn-JP',
            targetLanguage: 'kor-KR',
          ),
          const ModelCatalogEntryData(
            id: 'catalog.ko-ja',
            path: r'D:\models\ko-ja',
            displayName: 'Korean to Japanese model',
            family: 'transformers',
            readiness: 'runtime_required',
            capabilities: ['translation'],
            assignedRoles: ['translation'],
            sourceLanguage: 'kor',
            targetLanguage: 'jpn',
          ),
        ]);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ModelSettingsPage(
              coreFactory: () => core,
              secretStore: ProviderSecretStore(_MemorySecrets()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _expandTranslationRoutes(tester);

      expect(find.textContaining('英译中 · 英译中本地模型'), findsOneWidget);
      expect(find.textContaining('中译英 · 中译英本地模型'), findsOneWidget);
      expect(find.textContaining('日译韩 · 日译韩本地模型'), findsOneWidget);
      expect(find.textContaining('韩译日 · 韩译日本地模型'), findsOneWidget);
      expect(find.text('配置冲突'), findsNothing);

      await _expandConfiguredModels(tester);
      final englishChineseRoles = find.byKey(
        const ValueKey('provider-roles-en-zh-route'),
      );
      await tester.ensureVisible(englishChineseRoles);
      await tester.tap(englishChineseRoles);
      await tester.pumpAndSettle();
      await tester.tap(find.text('翻译').last);
      await tester.pumpAndSettle();

      expect(
        core.profiles
            .singleWhere((profile) => profile.id == 'en-zh-route')
            .assignedRoles,
        isEmpty,
      );
      expect(
        core.profiles
            .singleWhere((profile) => profile.id == 'en-zh-route')
            .enabled,
        isFalse,
      );
      expect(
        core.profiles
            .singleWhere((profile) => profile.id == 'zh-en-route')
            .assignedRoles,
        contains(ModelRole.translation),
      );
      for (final profileId in ['ja-ko-route', 'ko-ja-route']) {
        expect(
          core.profiles
              .singleWhere((profile) => profile.id == profileId)
              .assignedRoles,
          contains(ModelRole.translation),
        );
      }
      expect(
        core.catalog
            .singleWhere((entry) => entry.id == 'catalog.en-zh')
            .assignedRoles,
        isEmpty,
      );
      expect(
        core.catalog
            .singleWhere((entry) => entry.id == 'catalog.zh-en')
            .assignedRoles,
        contains('translation'),
      );
      for (final catalogId in ['catalog.ja-ko', 'catalog.ko-ja']) {
        expect(
          core.catalog
              .singleWhere((entry) => entry.id == catalogId)
              .assignedRoles,
          contains('translation'),
        );
      }
      expect(find.textContaining('中译英 · 中译英本地模型'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'selecting a local route replaces only the same language direction',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final core = _FakeCore()
        ..profiles.addAll([
          const ProviderProfileData(
            id: 'old-en-zh',
            displayName: '旧英译中',
            kind: ProviderProfileKind.localModel,
            enabled: true,
            modelId: 'old-en-zh',
            modelPath: r'D:\models\old-en-zh',
            assignedRoles: {ModelRole.translation},
          ),
          const ProviderProfileData(
            id: 'next-en-zh',
            displayName: '新英译中',
            kind: ProviderProfileKind.localModel,
            enabled: false,
            modelId: 'next-en-zh',
            modelPath: r'D:\models\next-en-zh',
          ),
          const ProviderProfileData(
            id: 'active-zh-en',
            displayName: '中译英',
            kind: ProviderProfileKind.localModel,
            enabled: true,
            modelId: 'zh-en',
            modelPath: r'D:\models\zh-en',
            assignedRoles: {ModelRole.translation},
          ),
        ])
        ..catalog.addAll([
          const ModelCatalogEntryData(
            id: 'catalog.old-en-zh',
            path: r'D:\models\old-en-zh',
            displayName: '旧英译中',
            family: 'transformers',
            readiness: 'runtime_required',
            capabilities: ['translation'],
            assignedRoles: ['translation'],
            sourceLanguage: 'english',
            targetLanguage: 'chinese',
          ),
          const ModelCatalogEntryData(
            id: 'catalog.next-en-zh',
            path: r'D:\models\next-en-zh',
            displayName: '新英译中',
            family: 'transformers',
            readiness: 'runtime_required',
            capabilities: ['translation'],
            assignedRoles: [],
            sourceLanguage: 'english',
            targetLanguage: 'chinese',
          ),
          const ModelCatalogEntryData(
            id: 'catalog.active-zh-en',
            path: r'D:\models\zh-en',
            displayName: '中译英',
            family: 'transformers',
            readiness: 'runtime_required',
            capabilities: ['translation'],
            assignedRoles: ['translation'],
            sourceLanguage: 'chinese',
            targetLanguage: 'english',
          ),
        ]);

      Widget settings() => MaterialApp(
        home: Scaffold(
          body: ModelSettingsPage(
            coreFactory: () => core,
            secretStore: ProviderSecretStore(_MemorySecrets()),
          ),
        ),
      );

      await tester.pumpWidget(settings());
      await tester.pumpAndSettle();
      expect(find.text('配置冲突'), findsNothing);
      await _expandConfiguredModels(tester);
      final chooseNextRoute = find.descendant(
        of: find.byKey(const ValueKey('next-en-zh')),
        matching: find.widgetWithText(TextButton, '设为翻译'),
      );
      await tester.ensureVisible(chooseNextRoute);
      await tester.tap(chooseNextRoute);
      await tester.pumpAndSettle();

      expect(
        core.profiles
            .firstWhere((profile) => profile.id == 'old-en-zh')
            .enabled,
        isFalse,
      );
      expect(
        core.profiles
            .firstWhere((profile) => profile.id == 'old-en-zh')
            .assignedRoles,
        isEmpty,
      );
      expect(
        core.profiles
            .firstWhere((profile) => profile.id == 'next-en-zh')
            .enabled,
        isTrue,
      );
      expect(
        core.profiles
            .firstWhere((profile) => profile.id == 'next-en-zh')
            .assignedRoles,
        contains(ModelRole.translation),
      );
      expect(
        core.profiles
            .firstWhere((profile) => profile.id == 'active-zh-en')
            .enabled,
        isTrue,
      );
      expect(
        core.profiles
            .firstWhere((profile) => profile.id == 'active-zh-en')
            .assignedRoles,
        contains(ModelRole.translation),
      );
      expect(
        core.catalog
            .firstWhere((entry) => entry.id == 'catalog.old-en-zh')
            .assignedRoles,
        isNot(contains('translation')),
      );
      expect(
        core.catalog
            .firstWhere((entry) => entry.id == 'catalog.next-en-zh')
            .assignedRoles,
        contains('translation'),
      );
      expect(
        core.catalog
            .firstWhere((entry) => entry.id == 'catalog.active-zh-en')
            .assignedRoles,
        contains('translation'),
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(settings());
      await tester.pumpAndSettle();
      await _expandTranslationRoutes(tester);
      expect(find.text('配置冲突'), findsNothing);
      expect(find.textContaining('英译中 · 新英译中'), findsOneWidget);
      expect(find.textContaining('中译英 · 中译英'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'roleless Qwen does not replace the bundled translation default',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final core = _FakeCore()
        ..profiles.add(
          const ProviderProfileData(
            id: 'legacy-qwen',
            displayName: '千问兼容接口',
            kind: ProviderProfileKind.remoteApi,
            enabled: true,
            modelId: 'qwen3.5:4b',
            endpoint: 'http://127.0.0.1:11434/v1',
          ),
        );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ModelSettingsPage(
              coreFactory: () => core,
              secretStore: ProviderSecretStore(_MemorySecrets()),
              bundledModelRootPath: r'D:\译学\bundled-models',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await _expandConfiguredModels(tester);
      await _expandRoleMap(tester);

      expect(find.text('随包英汉模型'), findsOneWidget);
      expect(find.text('千问兼容接口（当前使用）'), findsNothing);
    },
  );

  testWidgets('role map shows explicitly assigned remote capabilities', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final core = _FakeCore()
      ..profiles.add(
        const ProviderProfileData(
          id: 'local-understanding',
          displayName: '本地理解模型',
          kind: ProviderProfileKind.remoteApi,
          enabled: true,
          modelId: 'qwen3.5:4b',
          endpoint: 'http://127.0.0.1:11434/v1',
          assignedRoles: {ModelRole.understanding},
        ),
      );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ModelSettingsPage(
            coreFactory: () => core,
            secretStore: ProviderSecretStore(_MemorySecrets()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _expandRoleMap(tester);
    expect(find.text('本地理解模型（当前使用）'), findsOneWidget);
    expect(find.textContaining('当前使用'), findsOneWidget);
  });

  testWidgets(
    'role map reports the same understanding provider selected by summary execution',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final core = _FakeCore()
        ..profiles.addAll([
          const ProviderProfileData(
            id: 'remote-summary',
            displayName: '云端总结模型',
            kind: ProviderProfileKind.remoteApi,
            enabled: true,
            modelId: 'summary-cloud',
            endpoint: 'https://api.example.com/v1',
            assignedRoles: {ModelRole.understanding},
          ),
          const ProviderProfileData(
            id: 'loopback-summary',
            displayName: '本机总结模型',
            kind: ProviderProfileKind.remoteApi,
            enabled: true,
            modelId: 'summary-local',
            endpoint: 'http://127.0.0.1:11434/v1',
            assignedRoles: {ModelRole.understanding},
          ),
        ]);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ModelSettingsPage(
              coreFactory: () => core,
              secretStore: ProviderSecretStore(_MemorySecrets()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _expandRoleMap(tester);

      expect(find.text('本机总结模型（当前使用）'), findsOneWidget);
      expect(find.text('云端总结模型（当前使用）'), findsNothing);
    },
  );

  testWidgets('assigns a role from a configured provider menu', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final core = _FakeCore()
      ..profiles.add(
        const ProviderProfileData(
          id: 'remote-understanding',
          displayName: '本地接口模型',
          kind: ProviderProfileKind.remoteApi,
          enabled: true,
          modelId: 'qwen3.5:4b',
          endpoint: 'http://127.0.0.1:11434/v1',
        ),
      );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ModelSettingsPage(
            coreFactory: () => core,
            secretStore: ProviderSecretStore(_MemorySecrets()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _expandConfiguredModels(tester);
    await tester.tap(
      find.byKey(const ValueKey('provider-roles-remote-understanding')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('理解与总结').last);
    await tester.pumpAndSettle();

    expect(
      core.profiles
          .singleWhere((profile) => profile.id == 'remote-understanding')
          .assignedRoles,
      {ModelRole.understanding},
    );
  });

  testWidgets(
    'does not expose unsupported understanding role for native local models',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final core = _FakeCore()
        ..profiles.add(
          const ProviderProfileData(
            id: 'native-local-understanding',
            displayName: '原生本地理解模型',
            kind: ProviderProfileKind.localModel,
            enabled: true,
            modelId: 'native-qwen',
            modelPath: r'D:\models\native-qwen',
            assignedRoles: {ModelRole.translation, ModelRole.understanding},
          ),
        );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ModelSettingsPage(
              coreFactory: () => core,
              secretStore: ProviderSecretStore(_MemorySecrets()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await _expandConfiguredModels(tester);
      await tester.tap(
        find.byKey(const ValueKey('provider-roles-native-local-understanding')),
      );
      await tester.pumpAndSettle();

      expect(find.text('理解与总结'), findsNothing);

      await tester.tapAt(const Offset(40, 40));
      await tester.pumpAndSettle();
      await _expandRoleMap(tester);
      expect(find.text('未配置理解与总结模型；本用途仅支持兼容 API。'), findsOneWidget);
    },
  );

  testWidgets('deletes a configured provider only after confirmation', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final core = _FakeCore()
      ..profiles.add(
        const ProviderProfileData(
          id: 'api-to-delete',
          displayName: '待删除 API',
          kind: ProviderProfileKind.remoteApi,
          enabled: true,
          modelId: 'translator',
          endpoint: 'https://api.example.com/v1',
          secretRef: 'secret-to-delete',
        ),
      );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ModelSettingsPage(
            coreFactory: () => core,
            secretStore: ProviderSecretStore(_MemorySecrets()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _expandConfiguredModels(tester);
    await tester.tap(
      find.byKey(const ValueKey('provider-actions-api-to-delete')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除配置'));
    await tester.pumpAndSettle();
    expect(find.text('删除待删除 API？'), findsOneWidget);
    expect(core.profiles, hasLength(1));

    await tester.tap(find.text('确认删除'));
    await tester.pumpAndSettle();

    expect(core.profiles, isEmpty);
    expect(find.text('待删除 API'), findsNothing);
  });

  testWidgets('edits a configured API provider from its overview card', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final core = _FakeCore()
      ..profiles.add(
        const ProviderProfileData(
          id: 'api-edit',
          displayName: '旧名称',
          kind: ProviderProfileKind.remoteApi,
          enabled: true,
          modelId: 'old-model',
          endpoint: 'https://api.example.com/v1',
          secretRef: 'secret-edit',
        ),
      );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ModelSettingsPage(
            coreFactory: () => core,
            secretStore: ProviderSecretStore(_MemorySecrets()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _expandConfiguredModels(tester);
    await tester.tap(find.byKey(const ValueKey('provider-actions-api-edit')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑配置'));
    await tester.pumpAndSettle();
    expect(find.textContaining('保存不会改变当前启用状态'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, '配置 ID'), findsNothing);
    await _expandRemoteProviderAdvanced(tester);
    final idField = tester.widget<TextField>(
      find.widgetWithText(TextField, '配置 ID'),
    );
    expect(idField.readOnly, isTrue);
    expect(idField.controller?.text, 'api-edit');
    await tester.enterText(find.widgetWithText(TextFormField, '显示名称'), '新名称');
    await tester.enterText(
      find.widgetWithText(TextFormField, '模型 ID'),
      'new-model',
    );
    await tester.tap(find.text('保存修改'));
    await tester.pumpAndSettle();

    expect(core.profiles.single.displayName, '新名称');
    expect(core.profiles.single.modelId, 'new-model');
    expect(core.profiles.single.id, 'api-edit');
    expect(core.profiles.single.secretRef, 'secret-edit');
    expect(core.profiles.single.enabled, isTrue);
    expect(find.text('新名称'), findsOneWidget);
  });

  testWidgets('tests an API provider without changing the selected provider', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final core = _FakeCore()
      ..profiles.addAll([
        const ProviderProfileData(
          id: 'api-current',
          displayName: '当前 API',
          kind: ProviderProfileKind.remoteApi,
          enabled: true,
          modelId: 'translator-current',
          endpoint: 'https://api.example.com/v1',
          secretRef: 'secret-current',
        ),
        const ProviderProfileData(
          id: 'api-other',
          displayName: '备用 API',
          kind: ProviderProfileKind.remoteApi,
          enabled: false,
          modelId: 'translator-other',
          endpoint: 'https://api.example.com/v1',
          secretRef: 'secret-other',
        ),
      ]);
    ProviderProfileData? tested;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ModelSettingsPage(
            coreFactory: () => core,
            secretStore: ProviderSecretStore(_MemorySecrets()),
            connectivityTester: (profile) async => tested = profile,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _expandConfiguredModels(tester);
    await tester.tap(
      find.byKey(const ValueKey('provider-actions-api-current')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('测试连接'));
    await tester.pumpAndSettle();

    expect(tested?.id, 'api-current');
    expect(
      core.profiles
          .firstWhere((profile) => profile.id == 'api-current')
          .enabled,
      isTrue,
    );
    expect(
      core.profiles.firstWhere((profile) => profile.id == 'api-other').enabled,
      isFalse,
    );
    expect(find.text('当前 API连接正常'), findsOneWidget);
  });

  testWidgets('runs an API capability trial without changing the provider', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final core = _FakeCore()
      ..profiles.add(
        const ProviderProfileData(
          id: 'api-trial',
          displayName: '试跑 API',
          kind: ProviderProfileKind.remoteApi,
          enabled: true,
          modelId: 'translator',
          endpoint: 'https://api.example.com/v1',
          secretRef: 'secret-trial',
        ),
      );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ModelSettingsPage(
            coreFactory: () => core,
            secretStore: ProviderSecretStore(_MemorySecrets()),
            capabilityTrialer: (_) async => const ModelCapabilityTrialResult(
              status: CapabilityTrialStatus.passed,
              detail: '最小翻译试跑通过，可以用于后续任务；完整质量仍需固定集和人工评测。',
              translated: '你好。',
              elapsed: Duration(milliseconds: 18),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _expandConfiguredModels(tester);
    await tester.tap(find.byKey(const ValueKey('provider-actions-api-trial')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('能力试跑'));
    await tester.pumpAndSettle();

    expect(find.text('试跑 API · 能力试跑通过'), findsOneWidget);
    expect(find.text('你好。'), findsOneWidget);
    expect(core.profiles.single.enabled, isTrue);
  });

  testWidgets('restores the bundled bilingual translation route explicitly', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final core = _FakeCore()
      ..profiles.add(
        const ProviderProfileData(
          id: 'custom-translation',
          displayName: '自定义千问',
          kind: ProviderProfileKind.remoteApi,
          enabled: true,
          modelId: 'qwen3.5:4b',
          endpoint: 'http://127.0.0.1:11434/v1',
          assignedRoles: {ModelRole.translation},
        ),
      );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ModelSettingsPage(
            coreFactory: () => core,
            secretStore: ProviderSecretStore(_MemorySecrets()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final currentRoute = find.byKey(
      const ValueKey('current-translation-provider'),
    );
    expect(tester.widget<Text>(currentRoute).data, '当前翻译：自定义千问');

    final restore = find.byKey(
      const ValueKey('restore-bundled-translation-provider'),
    );
    expect(restore, findsOneWidget);
    await tester.tap(restore);
    await tester.pumpAndSettle();

    expect(tester.widget<Text>(currentRoute).data, '当前翻译：译学随包英汉模型');
    expect(core.profiles.single.enabled, isFalse);
    expect(core.profiles.single.assignedRoles, isEmpty);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'allows an explicit capability trial before enabling a remote provider',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final core = _FakeCore()
        ..profiles.add(
          const ProviderProfileData(
            id: 'api-disabled-trial',
            displayName: '未启用 API',
            kind: ProviderProfileKind.remoteApi,
            enabled: false,
            modelId: 'translator',
            endpoint: 'https://api.example.com/v1',
            secretRef: 'secret-trial',
          ),
        );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ModelSettingsPage(
              coreFactory: () => core,
              secretStore: ProviderSecretStore(_MemorySecrets()),
              capabilityTrialer: (_) async => const ModelCapabilityTrialResult(
                status: CapabilityTrialStatus.passed,
                detail: '仅完成一次用户主动发起的能力试跑。',
                translated: '你好。',
                elapsed: Duration(milliseconds: 18),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _expandConfiguredModels(tester);
      await tester.tap(
        find.byKey(const ValueKey('provider-actions-api-disabled-trial')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('能力试跑'));
      await tester.pumpAndSettle();

      expect(find.text('未启用 API · 能力试跑通过'), findsOneWidget);
      expect(core.profiles.single.enabled, isFalse);
      expect(core.profiles.single.assignedRoles, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('marks missing discovered paths and removes only the record', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final core = _FakeCore();
    core.catalog.add(
      const ModelCatalogEntryData(
        id: 'catalog.qwen.missing',
        path: r'D:\models\missing-qwen',
        displayName: '失效千问记录',
        family: 'qwen',
        readiness: 'runtime_required',
        capabilities: ['general_text'],
        assignedRoles: [],
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ModelSettingsPage(coreFactory: () => core)),
      ),
    );
    await tester.pumpAndSettle();

    await _expandDiscoveredModels(tester);
    expect(find.textContaining('路径已失效'), findsOneWidget);
    final removeRecord = find.byTooltip('移除发现记录');
    await tester.ensureVisible(removeRecord);
    await tester.tap(removeRecord);
    await tester.pumpAndSettle();
    expect(find.text('移除失效千问记录记录？'), findsOneWidget);
    await tester.tap(find.text('移除记录'));
    await tester.pumpAndSettle();

    expect(core.catalog, isEmpty);
    expect(find.text('失效千问记录'), findsNothing);
  });
}

Future<void> _tapModelDiscoveryAction(
  WidgetTester tester,
  String actionLabel,
) async {
  final section = find.text('查找已经下载的模型');
  await tester.ensureVisible(section);
  await tester.tap(section);
  await tester.pumpAndSettle();

  final action = find.text(actionLabel);
  await tester.ensureVisible(action);
  await tester.tap(action);
  await tester.pumpAndSettle();
}

Future<void> _expandDiscoveredModels(WidgetTester tester) async {
  final section = find.byWidgetPredicate(
    (widget) =>
        widget is Text && (widget.data?.startsWith('其他已发现模型（') ?? false),
  );
  await tester.ensureVisible(section);
  await tester.tap(section);
  await tester.pumpAndSettle();
}

Future<void> _expandConfiguredModels(WidgetTester tester) async {
  for (final key in const ['local-models-category', 'api-models-category']) {
    final section = find.byKey(ValueKey(key));
    if (section.evaluate().isEmpty) continue;
    await tester.ensureVisible(section);
    await tester.tap(section);
    await tester.pumpAndSettle();
  }
}

Future<void> _expandTranslationRoutes(WidgetTester tester) async {
  final section = find.byKey(
    const ValueKey('translation-direction-routes-toggle'),
  );
  await tester.ensureVisible(section);
  await tester.tap(section);
  await tester.pumpAndSettle();
}

Future<void> _expandRoleMap(WidgetTester tester) async {
  final section = find.text('模型用途与优先级');
  await tester.ensureVisible(section);
  await tester.tap(section);
  await tester.pumpAndSettle();
}

Future<void> _expandRemoteProviderPresets(WidgetTester tester) async {
  final section = find.byKey(const ValueKey('provider-presets'));
  await tester.ensureVisible(section);
  await tester.tap(section);
  await tester.pumpAndSettle();
}

Future<void> _expandRemoteProviderAdvanced(WidgetTester tester) async {
  final section = find.byKey(const ValueKey('provider-advanced-options'));
  await tester.ensureVisible(section);
  await tester.tap(section);
  await tester.pumpAndSettle();
}
