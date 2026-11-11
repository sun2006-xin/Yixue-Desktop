import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:yixue_app/core/learning_workbench.dart';
import 'package:yixue_app/core/native_core_bridge.dart';
import 'package:yixue_app/core/model_package_discovery_service.dart';
import 'package:yixue_app/core/openai_compatible_translation_client.dart';
import 'package:yixue_app/core/provider_configuration_service.dart';
import 'package:yixue_app/core/provider_secret_store.dart';

typedef LearningSentenceExerciseGenerator =
    Future<List<LearningSentenceExerciseData>> Function({
      required String scenario,
      required int difficulty,
      required int count,
    });

/// The provider-backed part of article and sentence learning.
///
/// Summaries and generated learning exercises are only sent to an enabled
/// OpenAI-compatible API profile assigned to [ModelRole.understanding]. Native
/// local-model profiles are not supported by this HTTP client. Translation
/// providers are never silently reused for this job. Loopback compatible API
/// endpoints are preferred so a locally hosted server can remain local.
final class LearningSummaryService {
  LearningSummaryService({
    required this._coreFactory,
    ProviderSecretStore? secrets,
    http.Client? httpClient,
    Duration timeout = const Duration(seconds: 45),
  }) : _ownsHttpClient = httpClient == null,
       _client = OpenAiCompatibleTranslationClient(
         httpClient: httpClient ?? http.Client(),
         secrets: secrets ?? ProviderSecretStore.platform(),
         timeout: timeout,
       );

  final AppCore Function() _coreFactory;
  final bool _ownsHttpClient;
  final OpenAiCompatibleTranslationClient _client;

  Future<String> summarize(String text) async {
    final profile = _loadSummaryProfile();
    if (profile == null) {
      throw const LearningSummaryException('no_summary_model');
    }
    try {
      return await _client.summarize(profile: profile, sourceText: text);
    } on TranslationClientException catch (error) {
      throw LearningSummaryException(error.code, statusCode: error.statusCode);
    }
  }

  Future<List<LearningSentenceExerciseData>> generateSentenceExercises({
    required String scenario,
    required int difficulty,
    required int count,
  }) async {
    final topic = scenario.trim();
    if (topic.isEmpty ||
        topic.length > 80 ||
        difficulty < 1 ||
        difficulty > 3 ||
        !const {1, 3, 5, 10}.contains(count)) {
      throw const LearningSummaryException('invalid_sentence_request');
    }
    final profile = _loadSummaryProfile();
    if (profile == null) {
      throw const LearningSummaryException('no_summary_model');
    }
    try {
      final response = await _client.generateSentenceExercises(
        profile: profile,
        scenario: topic,
        difficulty: difficulty,
        count: count,
      );
      return _parseSentenceExercises(response, expectedCount: count);
    } on TranslationClientException catch (error) {
      throw LearningSummaryException(error.code, statusCode: error.statusCode);
    } on FormatException {
      throw const LearningSummaryException('invalid_sentence_response');
    }
  }

  static List<LearningSentenceExerciseData> _parseSentenceExercises(
    String raw, {
    required int expectedCount,
  }) {
    if (raw.trim().length > 16000) {
      throw const FormatException('句子练习响应过长');
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic> ||
        decoded.length != 1 ||
        !decoded.containsKey('sentences')) {
      throw const FormatException('句子练习 JSON 结构无效');
    }
    final rows = decoded['sentences'];
    if (rows is! List || rows.length != expectedCount) {
      throw const FormatException('句子练习数量与请求不一致');
    }
    final result = <LearningSentenceExerciseData>[];
    final sentencePairs = <String>{};
    for (final row in rows) {
      if (row is! Map<String, dynamic> ||
          row.length != 3 ||
          !row.containsKey('title') ||
          !row.containsKey('chinese') ||
          !row.containsKey('english')) {
        throw const FormatException('句子练习字段无效');
      }
      final title = row['title'];
      final chinese = row['chinese'];
      final english = row['english'];
      if (title is! String ||
          chinese is! String ||
          english is! String ||
          title.trim().isEmpty ||
          chinese.trim().isEmpty ||
          english.trim().isEmpty ||
          title.trim().length > 100 ||
          chinese.trim().length > 500 ||
          english.trim().length > 500) {
        throw const FormatException('句子练习内容为空或超出长度');
      }
      final pairKey = '${chinese.trim()}\u0000${english.trim().toLowerCase()}';
      if (!sentencePairs.add(pairKey)) {
        throw const FormatException('句子练习包含重复内容');
      }
      result.add(
        LearningSentenceExerciseData(
          title: title.trim(),
          chineseText: chinese.trim(),
          englishText: english.trim(),
        ),
      );
    }
    return List.unmodifiable(result);
  }

  ProviderProfileData? _loadSummaryProfile() {
    final core = _coreFactory();
    try {
      return selectProvider(core.listProviderProfiles());
    } finally {
      core.dispose();
    }
  }

  static ProviderProfileData? selectProvider(
    Iterable<ProviderProfileData> profiles,
  ) {
    final candidates = profiles
        .where(
          (profile) =>
              profile.enabled &&
              profile.kind == ProviderProfileKind.remoteApi &&
              profile.modelId.trim().isNotEmpty &&
              profile.assignedRoles.contains(ModelRole.understanding),
        )
        .toList();
    if (candidates.isEmpty) return null;
    candidates.sort((left, right) {
      final localOrder = _localPriority(left) - _localPriority(right);
      if (localOrder != 0) return localOrder;
      return left.displayName.compareTo(right.displayName);
    });
    return candidates.first;
  }

  static int _localPriority(ProviderProfileData profile) =>
      isLocalCompatibleEndpoint(profile.endpoint) ? 0 : 1;

  void close() {
    if (_ownsHttpClient) _client.close();
  }
}

final class LearningSummaryException implements Exception {
  const LearningSummaryException(this.code, {this.statusCode});

  final String code;
  final int? statusCode;

  String get message => switch (code) {
    'no_summary_model' => '请先在“模型与服务”中为一个兼容 API 模型分配“理解与总结”用途；原生本地模型暂不支持此服务。',
    'provider_unavailable' => '当前总结模型不可用，请检查模型是否已启用。',
    'provider_invalid' => '理解与总结模型配置不完整，请检查服务地址和模型名称。',
    'missing_credential' => '总结模型缺少 API 密钥，请在模型设置中补充。',
    'request_timeout' => '总结模型响应超时，请稍后重试。',
    'network_error' => '无法连接总结模型，请检查本地接口或网络。',
    'invalid_response' => '模型返回了无法识别的内容，请重试或检查模型服务。',
    'invalid_sentence_response' => '模型返回的句子格式或数量不正确，请减少题量或换用更稳定的模型后重试。',
    'invalid_sentence_request' => '请检查场景、难度和题量后重试。',
    'remote_service_error' =>
      '总结模型服务返回错误${statusCode == null ? '' : '（$statusCode）'}。',
    'invalid_input' => '文章内容为空或超过总结长度限制。',
    _ => '文章总结失败，请检查模型设置后重试。',
  };

  @override
  String toString() => 'LearningSummaryException($code)';
}
