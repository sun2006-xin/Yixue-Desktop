import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/core/dictionary_catalog.dart';

void main() {
  test(
    'keeps official CET scope evidence separate from the open word list',
    () {
      expect(cetEnglishDictionaryScopeAudit.machineComparable, isFalse);
      expect(
        cetEnglishDictionaryScopeAudit.officialSourceUrl,
        startsWith('https://cet.neea.edu.cn/'),
      );
      expect(cetEnglishDictionaryScopeAudit.statusLabel, contains('无可机器比对词表'));
    },
  );
}
