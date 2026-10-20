import 'dart:async';
import 'dart:convert';

import 'package:fetchren/src/http/request_executor.dart';
import 'package:fetchren/src/http/request_outcome.dart';
import 'package:fetchren/src/models/api_request.dart';
import 'package:fetchren/src/models/http_method.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../support/fakes.dart';

void main() {
  group('RequestExecutor with mock transport', () {
    test('returns status, headers, decoded body, and elapsed time', () async {
      late http.Request captured;
      final executor = RequestExecutor(
        MockClient((request) async {
          captured = request;
          return http.Response(
            '{"ok":true}',
            200,
            headers: {'content-type': 'application/json', 'x-trace': 'abc'},
            reasonPhrase: 'OK',
          );
        }),
      );

      final outcome = await executor.execute(
        makeRequest(
          method: HttpMethod.post,
          url: 'https://api.example.test/items',
          headers: const [
            HeaderEntry(id: '1', name: 'Content-Type', value: 'text/plain'),
          ],
          body: 'hello',
        ),
      );

      expect(captured.method, 'POST');
      expect(captured.url.toString(), 'https://api.example.test/items');
      expect(captured.headers['Content-Type'], 'text/plain');
      expect(captured.body, 'hello');

      final response = outcome as ApiResponse;
      expect(response.statusCode, 200);
      expect(response.reasonPhrase, 'OK');
      expect(response.isSuccess, isTrue);
      expect(response.headers['x-trace'], 'abc');
      expect(response.contentType, 'application/json');
      expect(response.body, '{"ok":true}');
      expect(response.elapsed, greaterThanOrEqualTo(Duration.zero));
    });

    test('treats non-2xx statuses as responses, not failures', () async {
      for (final status in [301, 404, 500]) {
        final executor = RequestExecutor(
          MockClient((_) async => http.Response('nope', status)),
        );
        final outcome = await executor.execute(makeRequest());
        expect(outcome, isA<ApiResponse>());
        final response = outcome as ApiResponse;
        expect(response.statusCode, status);
        expect(response.isSuccess, isFalse);
        expect(response.body, 'nope');
      }
    });

    test('handles HEAD responses with an empty body', () async {
      final executor = RequestExecutor(
        MockClient((request) async {
          expect(request.method, 'HEAD');
          return http.Response('', 204);
        }),
      );
      final response = await executor.execute(
        makeRequest(method: HttpMethod.head),
      ) as ApiResponse;
      expect(response.statusCode, 204);
      expect(response.bodyBytes, isEmpty);
    });

    test('fails fast on invalid URL without touching the network', () async {
      var calls = 0;
      final executor = RequestExecutor(
        MockClient((_) async {
          calls++;
          return http.Response('', 200);
        }),
      );
      final outcome = await executor.execute(makeRequest(url: 'not a url'));
      expect((outcome as RequestFailure).kind, FailureKind.invalidUrl);
      expect(calls, 0);
    });

    test('reports unsupported schemes and invalid headers', () async {
      final executor = RequestExecutor(
        MockClient((_) async => http.Response('', 200)),
      );
      final scheme = await executor.execute(
        makeRequest(url: 'ftp://example.test'),
      );
      expect((scheme as RequestFailure).kind, FailureKind.unsupportedScheme);

      final header = await executor.execute(
        makeRequest(
          headers: const [HeaderEntry(id: '1', value: 'orphan')],
        ),
      );
      expect((header as RequestFailure).kind, FailureKind.invalidHeader);
    });

    test('maps transport exceptions to network failures', () async {
      final executor = RequestExecutor(
        MockClient((request) async {
          throw http.ClientException('Connection refused', request.url);
        }),
      );
      final failure = await executor.execute(makeRequest()) as RequestFailure;
      expect(failure.kind, FailureKind.network);
      expect(failure.message, 'Connection refused');
      expect(failure.elapsed, isNotNull);
    });

    test('maps other exceptions to network failures', () async {
      final executor = RequestExecutor(
        MockClient((_) async => throw const FormatException('TLS failure')),
      );
      final failure = await executor.execute(makeRequest()) as RequestFailure;
      expect(failure.kind, FailureKind.network);
      expect(failure.message, contains('TLS failure'));
    });

    test('times out when the server does not respond', () async {
      final never = Completer<http.Response>();
      final executor = RequestExecutor(
        MockClient((_) => never.future),
        timeout: const Duration(milliseconds: 50),
      );
      final failure = await executor.execute(makeRequest()) as RequestFailure;
      expect(failure.kind, FailureKind.timeout);
    });

    test('times out when the body stalls after headers', () async {
      final body = StreamController<List<int>>();
      addTearDown(body.close);
      final executor = RequestExecutor(
        MockClient.streaming(
          (_, _) async => http.StreamedResponse(body.stream, 200),
        ),
        timeout: const Duration(milliseconds: 50),
      );
      body.add(utf8.encode('partial'));
      final failure = await executor.execute(makeRequest()) as RequestFailure;
      expect(failure.kind, FailureKind.timeout);
    });

    test('rejects responses whose Content-Length exceeds the limit', () async {
      final executor = RequestExecutor(
        MockClient((_) async => http.Response('x' * 11, 200)),
        maxResponseBytes: 10,
      );
      final failure = await executor.execute(makeRequest()) as RequestFailure;
      expect(failure.kind, FailureKind.responseTooLarge);
      expect(failure.message, contains('10 B'));
    });

    test('rejects streamed responses that grow past the limit', () async {
      final executor = RequestExecutor(
        MockClient.streaming(
          (_, _) async => http.StreamedResponse(
            Stream.fromIterable([
              List.filled(6, 65),
              List.filled(6, 65),
              List.filled(6, 65),
            ]),
            200,
          ),
        ),
        maxResponseBytes: 10,
      );
      final failure = await executor.execute(makeRequest()) as RequestFailure;
      expect(failure.kind, FailureKind.responseTooLarge);
    });

    test('accepts a response exactly at the limit', () async {
      final executor = RequestExecutor(
        MockClient((_) async => http.Response('x' * 10, 200)),
        maxResponseBytes: 10,
      );
      final response = await executor.execute(makeRequest()) as ApiResponse;
      expect(response.bodyBytes.length, 10);
    });
  });

  group('decodeBody', () {
    test('defaults to lenient UTF-8', () {
      expect(decodeBody(utf8.encode('café'), null), 'café');
      expect(decodeBody([0xC3, 0x28], 'text/plain'), '\uFFFD(');
    });

    test('honours a declared Latin-1 charset', () {
      expect(
        decodeBody([0x63, 0x61, 0x66, 0xE9], 'text/plain; charset=ISO-8859-1'),
        'café',
      );
    });

    test('falls back to UTF-8 for unknown charsets', () {
      expect(decodeBody(utf8.encode('ok'), 'text/plain; charset=bogus'), 'ok');
    });
  });
}
