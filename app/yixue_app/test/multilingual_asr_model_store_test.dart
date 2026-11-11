import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/features/simultaneous_interpretation/multilingual_asr_model_store.dart';
import 'package:yixue_app/features/simultaneous_interpretation/streaming_asr_model_store.dart';

void main() {
  group('MultilingualAsrModelStore', () {
    test('pins a compact multilingual Whisper and Silero asset manifest', () {
      expect(MultilingualAsrModelStore.modelRevision, hasLength(40));
      expect(MultilingualAsrModelStore.assets, hasLength(4));
      expect(
        MultilingualAsrModelStore.assets.map((asset) => asset.fileName),
        <String>[
          'tiny-encoder.int8.onnx',
          'tiny-decoder.int8.onnx',
          'tiny-tokens.txt',
          'silero_vad.onnx',
        ],
      );
      expect(
        MultilingualAsrModelStore.assets.every(
          (asset) => RegExp(r'^[0-9a-f]{64}$').hasMatch(asset.sha256Hex),
        ),
        isTrue,
      );
      expect(
        MultilingualAsrModelStore.totalBytes,
        MultilingualAsrModelStore.assets.fold<int>(
          0,
          (sum, asset) => sum + asset.sizeBytes,
        ),
      );
    });

    test('resolves relative HTTPS redirects before validating the scheme', () {
      final resolved = StreamingAsrModelStore.resolveHttpsRedirect(
        Uri.https('huggingface.co', '/model/resolve/revision/file.txt'),
        '/api/resolve-cache/model/revision/file.txt',
      );

      expect(resolved.scheme, 'https');
      expect(resolved.host, 'huggingface.co');
      expect(resolved.path, '/api/resolve-cache/model/revision/file.txt');
    });

    test('rejects downgrade and credential-bearing redirects', () {
      final source = Uri.https('huggingface.co', '/model/file.txt');

      expect(
        () => StreamingAsrModelStore.resolveHttpsRedirect(
          source,
          'http://huggingface.co/model/file.txt',
        ),
        throwsA(
          isA<StreamingAsrModelStoreException>().having(
            (error) => error.code,
            'code',
            'download_redirect_rejected',
          ),
        ),
      );
      expect(
        () => StreamingAsrModelStore.resolveHttpsRedirect(
          source,
          'https://user:password@huggingface.co/model/file.txt',
        ),
        throwsA(isA<StreamingAsrModelStoreException>()),
      );
    });

    test(
      'model installation checks read disk without creating or downloading',
      () async {
        final temporary = await Directory.systemTemp.createTemp(
          'multilingual-asr-store-test-',
        );
        addTearDown(() => temporary.delete(recursive: true));
        final store = MultilingualAsrModelStore(
          applicationDataDirectory: temporary,
        );

        expect(await store.isInstalled(), isFalse);
        expect(await store.modelDirectory.exists(), isFalse);
        expect(await store.modelRoot.exists(), isFalse);
      },
    );

    test(
      'cancellation before install does not create a model directory',
      () async {
        final temporary = await Directory.systemTemp.createTemp(
          'multilingual-asr-store-test-',
        );
        addTearDown(() => temporary.delete(recursive: true));
        final store = MultilingualAsrModelStore(
          applicationDataDirectory: temporary,
        );

        await expectLater(
          store.downloadAndInstall(
            shouldCancel: () => true,
            onProgress: (_) {},
          ),
          throwsA(
            isA<StreamingAsrModelStoreException>().having(
              (error) => error.code,
              'code',
              'download_cancelled',
            ),
          ),
        );
        expect(await store.modelDirectory.exists(), isFalse);
      },
    );

    test(
      'an existing destination conflict is preserved without overwrite',
      () async {
        final temporary = await Directory.systemTemp.createTemp(
          'multilingual-asr-store-test-',
        );
        addTearDown(() => temporary.delete(recursive: true));
        final store = MultilingualAsrModelStore(
          applicationDataDirectory: temporary,
        );
        await store.modelDirectory.create(recursive: true);
        final marker = File(
          '${store.modelDirectory.path}${Platform.pathSeparator}keep.txt',
        );
        await marker.writeAsString('preserve');

        await expectLater(
          store.downloadAndInstall(
            shouldCancel: () => false,
            onProgress: (_) {},
          ),
          throwsA(
            isA<StreamingAsrModelStoreException>().having(
              (error) => error.code,
              'code',
              'destination_conflict',
            ),
          ),
        );
        expect(await marker.readAsString(), 'preserve');
      },
    );
  });
}
