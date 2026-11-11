/// Friendly starting points for remote providers.
///
/// The runtime does not route by vendor name. Every preset below is only a
/// group of editable defaults for the generic OpenAI-compatible adapter. A
/// provider that does not implement that protocol must receive its own client
/// later instead of being labelled as compatible.
class RemoteProviderPreset {
  const RemoteProviderPreset({
    required this.id,
    required this.label,
    required this.displayName,
    required this.endpoint,
    required this.modelId,
    required this.description,
  });

  final String id;
  final String label;
  final String displayName;
  final String endpoint;
  final String modelId;
  final String description;
}

const remoteProviderPresets = <RemoteProviderPreset>[
  RemoteProviderPreset(
    id: 'openai-compatible',
    label: '通用兼容 API',
    displayName: 'OpenAI 兼容接口',
    endpoint: 'https://api.openai.com/v1',
    modelId: '',
    description: '支持 OpenAI 兼容协议的厂商或本地服务；模型 ID 由服务方提供。',
  ),
  RemoteProviderPreset(
    id: 'deepseek-api',
    label: 'DeepSeek API',
    displayName: 'DeepSeek API',
    endpoint: 'https://api.deepseek.com',
    modelId: 'deepseek-flash',
    description: '使用官方当前 Flash 模型别名；仍需用户填写密钥并测试连接。',
  ),
];

RemoteProviderPreset? remoteProviderPresetById(String id) {
  for (final preset in remoteProviderPresets) {
    if (preset.id == id) return preset;
  }
  return null;
}
