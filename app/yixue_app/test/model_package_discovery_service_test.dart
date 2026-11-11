import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/core/model_package_discovery_service.dart';

void main() {
  late Directory sandbox;

  setUp(() async {
    final root = Directory(r'..\..\target\flutter-discovery-tests');
    await root.create(recursive: true);
    sandbox = await root.createTemp('case-');
  });

  tearDown(() async {
    if (await sandbox.exists()) await sandbox.delete(recursive: true);
  });

  test('finds only directories with a Yixue model manifest', () async {
    final valid = Directory('${sandbox.path}\\models\\opus-en-zh');
    final unrelated = Directory('${sandbox.path}\\models\\other');
    await valid.create(recursive: true);
    await unrelated.create(recursive: true);
    await File('${valid.path}\\yixue-model.json').writeAsString('{}');
    await File('${unrelated.path}\\config.json').writeAsString('{}');

    final found = await const ModelPackageDiscoveryService().discover(
      sandbox.path,
    );

    expect(found, <String>[valid.path]);
  });

  test('does not walk beyond the configured depth', () async {
    final tooDeep = Directory('${sandbox.path}\\one\\two');
    await tooDeep.create(recursive: true);
    await File('${tooDeep.path}\\yixue-model.json').writeAsString('{}');

    final found = await const ModelPackageDiscoveryService(maximumDepth: 1)
        .discover(sandbox.path);

    expect(found, isEmpty);
  });

  test(
    'recognizes a Qwen Transformers folder without treating it as invalid',
    () async {
      final qwen = Directory('${sandbox.path}\\models\\Qwen3-4B');
      await qwen.create(recursive: true);
      await File('${qwen.path}\\config.json').writeAsString(
        '{"model_type":"qwen3","architectures":["Qwen3ForCausalLM"]}',
      );
      await File('${qwen.path}\\model-00001-of-00002.safetensors')
          .writeAsBytes(const [0]);
      await File('${qwen.path}\\tokenizer.json').writeAsString('{}');

      final found = await const ModelPackageDiscoveryService().discoverModels([
        sandbox.path,
      ]);

      expect(found, hasLength(1));
      expect(found.single.family, ModelFamily.qwen);
      expect(found.single.readiness, ModelReadiness.runtimeRequired);
      expect(found.single.displayName, 'Qwen3-4B');
      expect(found.single.capabilities, {
        ModelCapability.generalText,
        ModelCapability.summarization,
      });
    },
  );

  test(
    'advertises translation only for an explicitly translation-named model',
    () async {
      final qwen = Directory('${sandbox.path}\\models\\qwen-translation-7b');
      await qwen.create(recursive: true);
      await File('${qwen.path}\\config.json')
          .writeAsString('{"model_type":"qwen2"}');
      await File('${qwen.path}\\model.safetensors').writeAsBytes(const [0]);

      final found = await const ModelPackageDiscoveryService().discoverModels([
        sandbox.path,
      ]);

      expect(found.single.capabilities, contains(ModelCapability.translation));
    },
  );

  test('catalogs GGUF and verified Yixue packages separately', () async {
    final gguf = Directory('${sandbox.path}\\models\\qwen-gguf');
    final yixue = Directory('${sandbox.path}\\models\\opus-en-zh');
    await gguf.create(recursive: true);
    await yixue.create(recursive: true);
    await File('${gguf.path}\\qwen2.5-3b-q4.gguf').writeAsBytes(const [0]);
    await File('${yixue.path}\\yixue-model.json').writeAsString('{}');

    final found = await const ModelPackageDiscoveryService().discoverModels([
      sandbox.path,
    ]);

    expect(found.map((model) => model.family), <ModelFamily>[
      ModelFamily.yixueTranslation,
      ModelFamily.gguf,
    ]);
    expect(found.first.readiness, ModelReadiness.readyToValidate);
    expect(found.last.readiness, ModelReadiness.runtimeRequired);
  });

  test(
    'inspects a selected Qwen folder and returns an actionable candidate',
    () async {
      final qwen = Directory('${sandbox.path}\\Qwen2.5-7B-Instruct');
      await qwen.create(recursive: true);
      await File('${qwen.path}\\config.json')
          .writeAsString('{"model_type":"qwen2"}');
      await File('${qwen.path}\\model.safetensors').writeAsBytes(const [0]);

      final found = await const ModelPackageDiscoveryService().inspectDirectory(
        qwen.path,
      );

      expect(found, isNotNull);
      expect(found!.family, ModelFamily.qwen);
      expect(found.userMessage, contains('已经找到'));
    },
  );

  test(
    'inspects a model library when the selected folder contains nested models',
    () async {
      final library = Directory('${sandbox.path}\\model-library');
      final nested = Directory('${library.path}\\opus-en-zh');
      await nested.create(recursive: true);
      await File('${nested.path}\\yixue-model.json').writeAsString('{}');

      final found = await const ModelPackageDiscoveryService().inspectDirectory(
        library.path,
      );

      expect(found, isNotNull);
      expect(found!.path, nested.path);
      expect(found.family, ModelFamily.yixueTranslation);
    },
  );

  test('recognizes manifests in a custom Ollama model library', () async {
    final manifest = File(
      '${sandbox.path}\\ollama-models\\manifests\\registry.ollama.ai'
      '\\library\\qwen3.5\\4b',
    );
    await manifest.parent.create(recursive: true);
    await manifest.writeAsString('{"schemaVersion":2}');

    final found = await const ModelPackageDiscoveryService().discoverModels([
      sandbox.path,
    ]);

    expect(found, hasLength(1));
    expect(found.single.family, ModelFamily.ollama);
    expect(found.single.displayName, 'qwen3.5:4b');
  });

  test('does not advertise embedding and intent models as translators', () async {
    final root = Directory(
      '${sandbox.path}\\ollama-models\\manifests\\registry.ollama.ai\\library',
    );
    final embedding = File('${root.path}\\qwen3-embedding\\0.6b');
    final intent = File('${root.path}\\ov_intent_analysis_sft\\v7_q8');
    await embedding.parent.create(recursive: true);
    await intent.parent.create(recursive: true);
    await embedding.writeAsString('{}');
    await intent.writeAsString('{}');

    final found = await const ModelPackageDiscoveryService().discoverModels([
      sandbox.path,
    ]);

    expect(found, hasLength(2));
    expect(found.first.capabilities, {ModelCapability.classification});
    expect(found.last.capabilities, {ModelCapability.embedding});
    expect(
      found.expand((model) => model.capabilities),
      isNot(contains(ModelCapability.translation)),
    );
  });

  test(
    'does not mislabel an unrelated ONNX file as a translation model',
    () async {
      final detector = Directory('${sandbox.path}\\object-detector');
      await detector.create(recursive: true);
      await File('${detector.path}\\best.onnx').writeAsBytes(const [0]);

      final found = await const ModelPackageDiscoveryService().discoverModels([
        sandbox.path,
      ]);

      expect(found, isEmpty);
    },
  );
}
