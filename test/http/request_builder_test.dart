import 'dart:convert';

import 'package:fetchren/src/http/request_builder.dart';
import 'package:fetchren/src/http/request_outcome.dart';
import 'package:fetchren_core/fetchren_core.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fakes.dart';

Matcher _rejectedAs(FailureKind kind) => throwsA(
  isA<RequestValidationException>().having((e) => e.kind, 'kind', kind),
);

void main() {
  group('parseRequestUrl', () {
    test('accepts http and https URLs and trims whitespace', () {
      expect(
        parseRequestUrl('  https://api.example.test/a?b=1 ').toString(),
        'https://api.example.test/a?b=1',
      );
      expect(parseRequestUrl('HTTP://localhost:8080').host, 'localhost');
    });

    test('rejects empty input', () {
      expect(() => parseRequestUrl('   '), _rejectedAs(FailureKind.invalidUrl));
    });

    test('rejects malformed URLs', () {
      expect(
        () => parseRequestUrl('http://[::1'),
        _rejectedAs(FailureKind.invalidUrl),
      );
    });

    test('rejects URLs without a scheme', () {
      expect(
        () => parseRequestUrl('api.example.test/items'),
        _rejectedAs(FailureKind.invalidUrl),
      );
    });

    test('rejects unsupported schemes', () {
      for (final url in [
        'ftp://example.test',
        'file:///etc/passwd',
        'javascript:alert(1)',
      ]) {
        expect(
          () => parseRequestUrl(url),
          _rejectedAs(FailureKind.unsupportedScheme),
          reason: url,
        );
      }
    });

    test('rejects URLs without a host', () {
      expect(
        () => parseRequestUrl('http:///path'),
        _rejectedAs(FailureKind.invalidUrl),
      );
    });

    test('rejects out-of-range ports and accepts valid ones', () {
      for (final port in ['0', '65536', '99999', '-1']) {
        expect(
          () => parseRequestUrl('http://localhost:$port/'),
          _rejectedAs(FailureKind.invalidUrl),
          reason: port,
        );
      }
      expect(parseRequestUrl('http://localhost:65535/').port, 65535);
      expect(parseRequestUrl('https://localhost/').port, 443);
    });
  });

  group('buildHeaders', () {
    test('includes enabled rows and skips disabled and blank rows', () {
      final headers = buildHeaders([
        const HeaderEntry(id: '1', name: 'Accept', value: 'application/json'),
        const HeaderEntry(id: '2', name: 'X-Off', value: 'x', enabled: false),
        const HeaderEntry(id: '3'),
        const HeaderEntry(id: '4', name: ' X-Trim ', value: ' v '),
      ]);
      expect(headers, {'Accept': 'application/json', 'X-Trim': 'v'});
    });

    test('combines repeated names case-insensitively', () {
      final headers = buildHeaders([
        const HeaderEntry(id: '1', name: 'X-Tag', value: 'a'),
        const HeaderEntry(id: '2', name: 'x-tag', value: 'b'),
      ]);
      expect(headers, {'X-Tag': 'a, b'});
    });

    test('allows an empty value', () {
      expect(buildHeaders([const HeaderEntry(id: '1', name: 'X-Empty')]), {
        'X-Empty': '',
      });
    });

    test('rejects a value without a name', () {
      expect(
        () => buildHeaders([const HeaderEntry(id: '1', value: 'orphan')]),
        _rejectedAs(FailureKind.invalidHeader),
      );
    });

    test('rejects invalid header names', () {
      expect(
        () => buildHeaders([
          const HeaderEntry(id: '1', name: 'Bad Name', value: 'x'),
        ]),
        _rejectedAs(FailureKind.invalidHeader),
      );
    });

    test('rejects line breaks in values (header injection)', () {
      for (final value in ['a\r\nX-Injected: 1', 'a\nb', 'a\u0000b']) {
        expect(
          () => buildHeaders([HeaderEntry(id: '1', name: 'X', value: value)]),
          _rejectedAs(FailureKind.invalidHeader),
        );
      }
    });

    test('rejects characters outside Latin-1', () {
      expect(
        () => buildHeaders([const HeaderEntry(id: '1', name: 'X', value: '✓')]),
        _rejectedAs(FailureKind.invalidHeader),
      );
    });
  });

  group('buildHttpRequest', () {
    test('sets method, URL, and headers', () {
      final request = buildHttpRequest(
        makeResolved(
          method: HttpMethod.options,
          url: 'https://api.example.test/x',
          headers: const [HeaderEntry(id: '1', name: 'Accept', value: '*/*')],
        ),
      );
      expect(request.method, 'OPTIONS');
      expect(request.url, Uri.parse('https://api.example.test/x'));
      expect(request.headers, {'Accept': '*/*'});
      expect(request.followRedirects, isFalse);
    });

    test('encodes the body as UTF-8 for methods that allow one', () {
      for (final method in HttpMethod.values.where((m) => m.allowsBody)) {
        final request = buildHttpRequest(
          makeResolved(method: method, body: '{"name":"café"}'),
        );
        expect(request.bodyBytes, utf8.encode('{"name":"café"}'));
        expect(
          request.headers.containsKey('content-type'),
          isFalse,
          reason: 'no implicit Content-Type',
        );
      }
    });

    test('omits the body for GET, HEAD, and OPTIONS', () {
      for (final method in [
        HttpMethod.get,
        HttpMethod.head,
        HttpMethod.options,
      ]) {
        final request = buildHttpRequest(
          makeResolved(method: method, body: 'ignored'),
        );
        expect(request.bodyBytes, isEmpty, reason: method.wireName);
      }
    });

    test('propagates validation failures', () {
      expect(
        () => buildHttpRequest(makeResolved(url: 'ws://example.test')),
        _rejectedAs(FailureKind.unsupportedScheme),
      );
    });
  });
}
