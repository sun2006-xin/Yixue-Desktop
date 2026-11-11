import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/features/simultaneous_interpretation/subtitle_text_presentation.dart';

void main() {
  test('converts all-uppercase English to sentence case for display', () {
    expect(
      formatSubtitleTextForDisplay(
        'I ALREADY DIED FOR YOU ONCE. NASA HELPED US.',
        languageCode: 'en',
      ),
      'I already died for you once. NASA helped US.',
    );
  });

  test('preserves mixed case and non-English transcript text', () {
    expect(
      formatSubtitleTextForDisplay('OpenAI works.', languageCode: 'en'),
      'OpenAI works.',
    );
    expect(
      formatSubtitleTextForDisplay('你好 WORLD', languageCode: 'zh'),
      '你好 WORLD',
    );
  });
}
