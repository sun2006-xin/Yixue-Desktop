import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/core/storage_policy.dart';

void main() {
  test(
    'storage policy defaults to unlimited and supports per-category quotas',
    () {
      final policy = StoragePolicy.unlimited().setQuota(
        StorageCategory.favoriteWords,
        1024 * 1024,
      );

      expect(policy.quotaFor(StorageCategory.translationHistory), isNull);
      expect(
        policy.isWithinQuota(StorageCategory.favoriteWords, usedBytes: 900000),
        isTrue,
      );
      expect(
        policy.isWithinQuota(
          StorageCategory.favoriteWords,
          usedBytes: 900000,
          additionalBytes: 200000,
        ),
        isFalse,
      );
    },
  );

  test(
    'storage policy persists and restores without losing unlimited categories',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'yixue-storage-policy-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final store = FileStoragePolicyStore(
        File('${directory.path}/storage-policy.json'),
      );
      final original = StoragePolicy.unlimited().setQuota(
        StorageCategory.dictionary,
        64 * 1024 * 1024,
      );

      await store.write(original);
      final restored = await store.read();

      expect(restored?.quotaFor(StorageCategory.dictionary), 64 * 1024 * 1024);
      expect(restored?.quotaFor(StorageCategory.favoriteWords), isNull);
    },
  );

  test('storage usage decodes logical category estimates', () {
    final usage = StorageUsageData.fromJson({
      'records': [
        {'category': 'favorite_words', 'used_bytes': 2048},
        {'category': 'dictionary', 'used_bytes': 4096},
      ],
    });

    expect(usage.forCategory(StorageCategory.favoriteWords), 2048);
    expect(usage.totalBytes, 6144);
  });
}
