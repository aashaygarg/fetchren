import 'package:fetchren/src/models/api_request.dart';
import 'package:fetchren/src/models/http_method.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fakes.dart';

void main() {
  test('generateId returns unique 32-character hex IDs', () {
    final ids = {for (var i = 0; i < 1000; i++) generateId()};
    expect(ids, hasLength(1000));
    expect(ids.every(RegExp(r'^[0-9a-f]{32}$').hasMatch), isTrue);
  });

  test('HttpMethod parses wire names case-insensitively', () {
    expect(HttpMethod.fromWireName('patch'), HttpMethod.patch);
    expect(() => HttpMethod.fromWireName('TRACE'), throwsFormatException);
  });

  test('isSensitiveHeader matches case-insensitively', () {
    expect(isSensitiveHeader(' Authorization '), isTrue);
    expect(isSensitiveHeader('PROXY-AUTHORIZATION'), isTrue);
    expect(isSensitiveHeader('Accept'), isFalse);
  });

  test('timestamps serialize as UTC ISO-8601', () {
    final json = makeRequest(createdAt: DateTime.utc(2026, 10, 21, 8, 30))
        .toJson();
    expect(json['createdAt'], '2026-10-21T08:30:00.000Z');
  });

  test('redactedForStorage keeps non-sensitive data', () {
    final request = makeRequest(
      headers: const [
        HeaderEntry(id: '1', name: 'Authorization', value: 'secret'),
        HeaderEntry(id: '2', name: 'Accept', value: '*/*'),
      ],
      body: 'body',
    );
    final redacted = request.redactedForStorage();
    expect(redacted.headers.map((h) => h.value), ['', '*/*']);
    expect(redacted.body, 'body');
    expect(redacted.id, request.id);
    expect(request.headers.first.value, 'secret', reason: 'original intact');
  });
}
