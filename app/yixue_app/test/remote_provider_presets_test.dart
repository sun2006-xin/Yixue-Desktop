import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/core/remote_provider_presets.dart';

void main() {
  test('keeps a generic OpenAI-compatible entry alongside vendor presets', () {
    final ids = remoteProviderPresets.map((preset) => preset.id).toSet();

    expect(ids, contains('openai-compatible'));
    expect(ids, contains('deepseek-api'));

    final generic = remoteProviderPresetById('openai-compatible');
    expect(generic, isNotNull);
    expect(generic!.modelId, isEmpty);
    expect(generic.endpoint, 'https://api.openai.com/v1');
    expect(generic.description, contains('兼容协议'));
  });

  test('unknown preset IDs do not create a fake provider', () {
    expect(remoteProviderPresetById('unknown-vendor'), isNull);
  });
}
