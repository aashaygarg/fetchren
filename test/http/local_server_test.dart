// Exercises the real http.Client against a loopback server; no external network.
import 'dart:convert';
import 'dart:io';

import 'package:fetchren/src/http/request_executor.dart';
import 'package:fetchren/src/http/request_outcome.dart';
import 'package:fetchren/src/models/api_request.dart';
import 'package:fetchren/src/models/http_method.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../support/fakes.dart';

void main() {
  late HttpServer server;
  late http.Client client;
  late String baseUrl;
  late List<String> hits;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    baseUrl = 'http://${server.address.host}:${server.port}';
    client = http.Client();
    hits = [];
    server.listen((request) async {
      hits.add(request.uri.path);
      final response = request.response;
      switch (request.uri.path) {
        case '/echo':
          final body = await utf8.decodeStream(request);
          response.headers.contentType = ContentType.json;
          response.write(
            jsonEncode({
              'method': request.method,
              'header': request.headers.value('x-test'),
              'body': body,
            }),
          );
        case '/missing':
          response.statusCode = HttpStatus.notFound;
          response.write('not found');
        case '/slow':
          await Future<void>.delayed(const Duration(seconds: 2));
          response.write('late');
        case '/big':
          for (var i = 0; i < 64; i++) {
            response.add(List.filled(1024, 97));
            await response.flush();
          }
        case '/gzip':
          response.headers.set('content-encoding', 'gzip');
          response.add(gzip.encode(List.filled(64 * 1024, 97)));
        case '/redirect':
          response.statusCode = HttpStatus.found;
          response.headers.set('location', '/target');
      }
      await response.close();
    });
  });

  tearDown(() async {
    client.close();
    await server.close(force: true);
  });

  test('round-trips method, headers, and body', () async {
    final executor = RequestExecutor(client);
    final response = await executor.execute(
      makeRequest(
        method: HttpMethod.put,
        url: '$baseUrl/echo',
        headers: const [HeaderEntry(id: '1', name: 'X-Test', value: 'hello')],
        body: 'payload',
      ),
    ) as ApiResponse;
    expect(response.statusCode, 200);
    expect(response.contentType, startsWith('application/json'));
    expect(jsonDecode(response.body), {
      'method': 'PUT',
      'header': 'hello',
      'body': 'payload',
    });
  });

  test('returns non-2xx responses', () async {
    final response = await RequestExecutor(
      client,
    ).execute(makeRequest(url: '$baseUrl/missing')) as ApiResponse;
    expect(response.statusCode, 404);
    expect(response.body, 'not found');
  });

  test('times out against a slow server', () async {
    final failure = await RequestExecutor(
      client,
      timeout: const Duration(milliseconds: 200),
    ).execute(makeRequest(url: '$baseUrl/slow')) as RequestFailure;
    expect(failure.kind, FailureKind.timeout);
  });

  test('aborts oversized chunked responses', () async {
    final failure = await RequestExecutor(
      client,
      maxResponseBytes: 8 * 1024,
    ).execute(makeRequest(url: '$baseUrl/big')) as RequestFailure;
    expect(failure.kind, FailureKind.responseTooLarge);
  });

  test('reports connection failures as network errors', () async {
    final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = closed.port;
    await closed.close();
    final failure = await RequestExecutor(
      client,
    ).execute(makeRequest(url: 'http://127.0.0.1:$port/')) as RequestFailure;
    expect(failure.kind, FailureKind.network);
  });

  test('limits decompressed size, not compressed size (gzip bomb)', () async {
    final failure = await RequestExecutor(
      client,
      maxResponseBytes: 8 * 1024,
    ).execute(makeRequest(url: '$baseUrl/gzip')) as RequestFailure;
    expect(failure.kind, FailureKind.responseTooLarge);
  });

  test('returns redirects instead of following them', () async {
    final response = await RequestExecutor(client).execute(
      makeRequest(
        url: '$baseUrl/redirect',
        headers: const [HeaderEntry(id: '1', name: 'X-API-Key', value: 'k')],
      ),
    ) as ApiResponse;
    expect(response.statusCode, HttpStatus.found);
    expect(response.headers['location'], '/target');
    expect(hits, ['/redirect'], reason: 'credentials not forwarded');
  });

  test('rejects out-of-range ports without throwing (regression)', () async {
    final failure = await RequestExecutor(
      client,
    ).execute(makeRequest(url: 'http://127.0.0.1:99999/')) as RequestFailure;
    expect(failure.kind, FailureKind.invalidUrl);
  });
}
