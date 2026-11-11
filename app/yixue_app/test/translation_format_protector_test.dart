import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/core/translation_format_protector.dart';

void main() {
  test('protects formatting spans and restores them in source order', () {
    final protected = TranslationFormatProtector.protect(
      'Open report_v2.3.pdf at 14:30 with Ctrl+L and {student_name}.',
    );

    expect(protected.maskedText, 'Open YXFMT at YXFMT with YXFMT and YXFMT.');
    expect(
      protected.restore('请在 YXFMT 打开文件，时间为 YXFMT，使用 YXFMT 和 YXFMT。'),
      '请在 report_v2.3.pdf 打开文件，时间为 14:30，使用 Ctrl+L 和 {student_name}。',
    );
  });

  test('protects URLs markdown currency units and API tokens', () {
    final protected = TranslationFormatProtector.protect(
      r'Keep **Important**, https://example.invalid/help, $0, 512 MB, and SHA-256.',
    );

    expect(protected.spans, [
      '**Important**',
      'https://example.invalid/help',
      r'$0',
      '512 MB',
      'SHA-256',
    ]);
    expect(
      protected.restore('保留 YXFMT、YXFMT、YXFMT、YXFMT 和 YXFMT。'),
      r'保留 **Important**、https://example.invalid/help、$0、512 MB 和 SHA-256。',
    );
  });

  test('escapes a literal sentinel in the source', () {
    final protected = TranslationFormatProtector.protect(
      'Keep YXFMT and v2.1.',
    );

    expect(protected.maskedText, 'Keep YXFMT and YXFMT.');
    expect(protected.restore('保留 YXFMT 和 YXFMT。'), '保留 YXFMT 和 v2.1。');
  });

  test('rejects missing duplicated or fabricated sentinels', () {
    final protected = TranslationFormatProtector.protect('Open v2.1 at 14:30.');

    expect(
      () => protected.restore('打开 YXFMT。'),
      throwsA(isA<TranslationFormatException>()),
    );
    expect(
      () => protected.restore('打开 YXFMT、YXFMT 和 YXFMT。'),
      throwsA(isA<TranslationFormatException>()),
    );
  });
}
