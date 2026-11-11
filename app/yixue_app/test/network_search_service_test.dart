import 'package:flutter_test/flutter_test.dart';
import 'package:yixue_app/core/network_search_service.dart';

void main() {
  test('builds a fixed HTTPS search URL without shell interpolation', () {
    final uri = NetworkSearchService.buildSearchUri('  hello & world  ');

    expect(uri.scheme, 'https');
    expect(uri.host, 'www.bing.com');
    expect(uri.path, '/search');
    expect(uri.queryParameters['q'], 'hello & world');
  });

  test('rejects empty, overlong and control-character queries', () {
    expect(
      () => NetworkSearchService.buildSearchUri('   '),
      throwsA(isA<NetworkSearchException>()),
    );
    expect(
      () => NetworkSearchService.buildSearchUri('a' * 201),
      throwsA(isA<NetworkSearchException>()),
    );
    expect(
      () => NetworkSearchService.buildSearchUri('hello\nworld'),
      throwsA(isA<NetworkSearchException>()),
    );
  });
}
