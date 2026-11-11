import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:yixue_app/core/learning_summary_service.dart';
import 'package:yixue_app/core/native_core_bridge.dart';
import 'package:yixue_app/core/openai_compatible_translation_client.dart';
import 'package:yixue_app/core/provider_configuration_service.dart';
import 'package:yixue_app/core/provider_secret_store.dart';

import 'subtitle_post_session_service.dart';

/// Explicit understanding-role Provider adapter for subtitle session reviews.
///
/// The selected Provider is disclosed to the history UI before any transcript
/// is sent. The same route is checked again around generation; there is no
/// fallback to a translation Provider or another network destination.
final class SubtitlePostSessionAiGenerator
    implements SubtitlePostSessionGenerator {
  SubtitlePostSessionAiGenerator({
    required AppCore Function() coreFactory,
    ProviderSecretStore? secrets,
    http.Client? httpClient,
  }) : _coreFactory = coreFactory,
       _ownsHttpClient = httpClient == null,
       _client = OpenAiCompatibleTranslationClient(
         httpClient: httpClient ?? http.Client(),
         secrets: secrets ?? ProviderSecretStore.platform(),
       );

  final AppCore Function() _coreFactory;
  final bool _ownsHttpClient;
  final OpenAiCompatibleTranslationClient _client;
  String? _lastDisclosedRouteKey;

  @override
  SubtitlePostSessionProviderInfo get providerInfo {
    final profile = _selectedProfile();
    _lastDisclosedRouteKey = _routeKey(profile);
    if (profile == null) {
      return const SubtitlePostSessionProviderInfo(
        providerName: '未配置理解与总结模型',
        kind: SubtitlePostSessionProviderKind.remote,
      );
    }
    final endpoint = _safeEndpointLabel(profile.endpoint);
    final local = isLocalCompatibleEndpoint(profile.endpoint);
    return SubtitlePostSessionProviderInfo(
      providerName: profile.displayName,
      kind: local
          ? SubtitlePostSessionProviderKind.local
          : SubtitlePostSessionProviderKind.remote,
      remoteDestinationLabel: local ? null : endpoint,
    );
  }

  @override
  Future<SubtitlePostSessionResult> generate(
    SubtitlePostSessionRequest request,
  ) async {
    final profile = _selectedProfile();
    if (profile == null) {
      throw const SubtitlePostSessionGenerationException(
        '没有可用的“理解与总结”Provider。请先在“模型与服务”中配置并启用一个。',
      );
    }
    final initialRoute = _routeKey(profile);
    if (_lastDisclosedRouteKey != initialRoute) {
      throw const SubtitlePostSessionGenerationException(
        'Provider 或处理位置在确认后发生变化，已阻止发送字幕。请重新打开复盘并确认新的数据去向。',
      );
    }
    final sourceReferences = <String, SubtitlePostSessionSourceSegment>{};
    final input = <String, Object?>{
      'sessionKind': request.sessionKind.name,
      'requestedOutputs': request.outputs.map(_outputName).toList(),
      'segments': <Map<String, Object?>>[
        for (var index = 0; index < request.segments.length; index++)
          _segmentJson(
            'S${index + 1}',
            request.segments[index],
            sourceReferences,
          ),
      ],
    };

    late final String response;
    try {
      response = await _client.reviewSubtitleSession(
        profile: profile,
        sourceJson: jsonEncode(input),
      );
    } on TranslationClientException catch (error) {
      throw SubtitlePostSessionGenerationException(_safeError(error));
    }

    if (_routeKey(_selectedProfile()) != initialRoute) {
      throw const SubtitlePostSessionGenerationException(
        '生成期间 Provider 或处理位置发生变化，本次复盘未保存。请重新确认后再试。',
      );
    }
    try {
      return _parseResult(
        response,
        request: request,
        sourceReferences: sourceReferences,
      );
    } on FormatException {
      throw const SubtitlePostSessionGenerationException(
        '复盘模型返回的结构或字幕来源无法核验，本次内容未保存。',
      );
    } on TypeError {
      throw const SubtitlePostSessionGenerationException(
        '复盘模型返回的结构或字幕来源无法核验，本次内容未保存。',
      );
    }
  }

  void close() {
    if (_ownsHttpClient) _client.close();
  }

  ProviderProfileData? _selectedProfile() {
    final core = _coreFactory();
    try {
      return LearningSummaryService.selectProvider(core.listProviderProfiles());
    } finally {
      core.dispose();
    }
  }

  static String _routeKey(ProviderProfileData? profile) {
    if (profile == null) return 'unavailable';
    return jsonEncode(<Object?>[
      profile.id,
      profile.displayName,
      profile.kind.name,
      profile.enabled,
      profile.modelId,
      profile.endpoint,
      profile.assignedRoles.map((role) => role.name).toList()..sort(),
    ]);
  }

  static String? _safeEndpointLabel(String? rawEndpoint) {
    final uri = Uri.tryParse(rawEndpoint?.trim() ?? '');
    if (uri == null || !uri.hasAuthority || uri.host.isEmpty) return null;
    final host = uri.host.contains(':') ? '[${uri.host}]' : uri.host;
    final port = uri.hasPort ? ':${uri.port}' : '';
    return '${uri.scheme}://$host$port';
  }

  static Map<String, Object?> _segmentJson(
    String refId,
    SubtitlePostSessionSourceSegment segment,
    Map<String, SubtitlePostSessionSourceSegment> sourceReferences,
  ) {
    sourceReferences[refId] = segment;
    return <String, Object?>{
      'refId': refId,
      'sourceKind': segment.sourceKind.name,
      'sourceLanguage': segment.sourceLanguageCode,
      'targetLanguage': segment.targetLanguageCode,
      'startMs': segment.startMs,
      'endMs': segment.endMs,
      'sourceText': segment.sourceText,
      'translatedText': segment.translatedText,
    };
  }

  static SubtitlePostSessionResult _parseResult(
    String rawResponse, {
    required SubtitlePostSessionRequest request,
    required Map<String, SubtitlePostSessionSourceSegment> sourceReferences,
  }) {
    final decoded = jsonDecode(rawResponse);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Expected a JSON object.');
    }
    final summaryPoints =
        request.outputs.contains(SubtitlePostSessionOutputKind.summary)
        ? _readList(decoded, 'summary').map((item) {
            final value = _readMap(item, 'summary item');
            return SubtitlePostSessionInsight(
              text: _readText(value['text'], 'summary text', maxLength: 1200),
              sources: _readSources(value, sourceReferences),
            );
          })
        : const <SubtitlePostSessionInsight>[];
    final terms =
        request.outputs.contains(SubtitlePostSessionOutputKind.terminology)
        ? _readList(decoded, 'terms').map((item) {
            final value = _readMap(item, 'term item');
            return SubtitlePostSessionTerm(
              term: _readText(value['term'], 'term', maxLength: 160),
              explanation: _readText(
                value['explanation'],
                'term explanation',
                maxLength: 600,
              ),
              sources: _readSources(value, sourceReferences),
            );
          })
        : const <SubtitlePostSessionTerm>[];
    final actions =
        request.outputs.contains(SubtitlePostSessionOutputKind.actionItems)
        ? _readList(decoded, 'actions').map((item) {
            final value = _readMap(item, 'action item');
            final owner = value['owner'];
            return SubtitlePostSessionActionItem(
              action: _readText(value['action'], 'action', maxLength: 600),
              owner: owner == null
                  ? null
                  : _readText(owner, 'action owner', maxLength: 120),
              sources: _readSources(value, sourceReferences),
            );
          })
        : const <SubtitlePostSessionActionItem>[];

    if (summaryPoints.length > 100 ||
        terms.length > 100 ||
        actions.length > 100) {
      throw const FormatException('Too many review items.');
    }
    return SubtitlePostSessionResult(
      generatedAtUtc: DateTime.now().toUtc(),
      summaryPoints: summaryPoints,
      terms: terms,
      actionItems: actions,
    );
  }

  static List<SubtitlePostSessionSourceRef> _readSources(
    Map<String, dynamic> value,
    Map<String, SubtitlePostSessionSourceSegment> sourceReferences,
  ) {
    final rawSources = value['sources'];
    if (rawSources is! List || rawSources.isEmpty || rawSources.length > 32) {
      throw const FormatException('Invalid source citations.');
    }
    final seen = <String>{};
    return rawSources
        .map((rawRef) {
          if (rawRef is! String || !seen.add(rawRef)) {
            throw const FormatException('Invalid source citation.');
          }
          final segment = sourceReferences[rawRef];
          if (segment == null) {
            throw const FormatException('Unknown subtitle source reference.');
          }
          return SubtitlePostSessionSourceRef(
            captureAttemptId: segment.captureAttemptId,
            segmentId: segment.segmentId,
            sourceId: segment.sourceId,
            sourceKind: segment.sourceKind,
            startMs: segment.startMs,
            endMs: segment.endMs,
          );
        })
        .toList(growable: false);
  }

  static List<dynamic> _readList(Map<String, dynamic> value, String key) {
    final list = value[key];
    if (list is! List) throw FormatException('Missing $key list.');
    return list;
  }

  static Map<String, dynamic> _readMap(Object? value, String name) {
    if (value is! Map<String, dynamic>) {
      throw FormatException('Invalid $name.');
    }
    return value;
  }

  static String _readText(
    Object? value,
    String name, {
    required int maxLength,
  }) {
    if (value is! String || value.trim().isEmpty || value.length > maxLength) {
      throw FormatException('Invalid $name.');
    }
    return value.trim();
  }

  static String _outputName(SubtitlePostSessionOutputKind output) =>
      switch (output) {
        SubtitlePostSessionOutputKind.summary => 'summary',
        SubtitlePostSessionOutputKind.terminology => 'terminology',
        SubtitlePostSessionOutputKind.actionItems => 'actionItems',
      };

  static String _safeError(
    TranslationClientException error,
  ) => switch (error.code) {
    'invalid_input' => '字幕内容过长，当前无法生成复盘；字幕原文仍保存在本机。',
    'missing_credential' => '当前复盘 Provider 缺少凭据，请检查“模型与服务”设置。',
    'provider_unavailable' ||
    'provider_invalid' => '当前复盘 Provider 不可用，字幕原文仍保存在本机。',
    'request_timeout' => '复盘请求超时；字幕原文仍保存在本机，可稍后重试。',
    'network_error' => '无法连接复盘 Provider；字幕原文仍保存在本机。',
    'remote_service_error' =>
      '复盘 Provider 返回错误${error.statusCode == null ? '' : '（${error.statusCode}）'}；字幕原文仍保存在本机。',
    _ => '复盘生成失败；字幕原文仍保存在本机，可检查 Provider 设置后重试。',
  };
}
