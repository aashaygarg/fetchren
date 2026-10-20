import 'dart:async';

import 'package:fetchren/src/http/request_executor.dart';
import 'package:fetchren/src/http/request_outcome.dart';
import 'package:fetchren/src/models/api_request.dart';
import 'package:fetchren/src/models/http_method.dart';
import 'package:fetchren/src/workbench/workbench_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../support/fakes.dart';

void main() {
  late InMemoryRequestStore store;
  late DateTime now;

  WorkbenchController build({http.Client? client}) => WorkbenchController(
    executor: RequestExecutor(
      client ?? MockClient((_) async => http.Response('{}', 200)),
    ),
    store: store,
    clock: () => now,
  );

  setUp(() {
    store = InMemoryRequestStore();
    now = DateTime.utc(2026, 10, 21, 9);
  });

  test('unexpected executor errors still end the loading state', () async {
    final controller = build(
      client: MockClient((_) => throw ArgumentError('boom')),
    )..setUrl('https://api.example.test');
    await controller.send();
    expect(controller.isSending, isFalse);
    expect((controller.outcome as RequestFailure).kind, FailureKind.network);
  });

  test('ignores repeated Send while a request is in flight', () async {
    final pending = Completer<http.Response>();
    var calls = 0;
    final controller = build(
      client: MockClient((_) {
        calls++;
        return pending.future;
      }),
    )..setUrl('https://api.example.test');
    final first = controller.send();
    await controller.send();
    pending.complete(http.Response('', 200));
    await first;
    expect(calls, 1);
  });

  test(
    'discards a response that arrives after another request is opened',
    () async {
      final pending = Completer<http.Response>();
      final controller = build(client: MockClient((_) => pending.future))
        ..setUrl('https://a.test');
      final sending = controller.send();
      controller.open(makeRequest(id: 'other', url: 'https://b.test'));
      pending.complete(http.Response('from a', 200));
      await sending;
      expect(controller.isSending, isFalse);
      expect(controller.outcome, isNull);
    },
  );

  test('disables saving when loading fails, to avoid overwriting', () async {
    store.failLoads = true;
    final controller = build();
    await controller.load();
    expect(controller.isLoaded, isTrue);
    controller.setUrl('https://a.test');
    await controller.save();
    expect(store.saveCount, 0);
    expect(controller.storageMessage, contains('Saving is disabled'));
  });

  test('load populates saved requests', () async {
    store.saved = [makeRequest(id: 'a')];
    final controller = build();
    expect(controller.isLoaded, isFalse);
    await controller.load();
    expect(controller.isLoaded, isTrue);
    expect(controller.savedRequests.single.id, 'a');
  });

  test('save creates a request with a stable ID and timestamps', () async {
    final controller = build()
      ..setMethod(HttpMethod.post)
      ..setUrl('https://api.example.test/a')
      ..setBody('x');
    await controller.save();

    final saved = store.saved.single;
    expect(saved.id, matches(RegExp(r'^[0-9a-f]{32}$')));
    expect(saved.createdAt, now);
    expect(saved.updatedAt, now);
    expect(saved.method, HttpMethod.post);
    expect(saved.name, 'https://api.example.test/a');
    expect(controller.activeId, saved.id);
  });

  test('saving again updates in place and keeps createdAt', () async {
    final controller = build()..setUrl('https://api.example.test/a');
    await controller.save();
    final id = controller.activeId;
    final created = now;

    now = now.add(const Duration(minutes: 5));
    controller.setUrl('https://api.example.test/b');
    await controller.save();

    final saved = store.saved.single;
    expect(saved.id, id);
    expect(saved.createdAt, created);
    expect(saved.updatedAt, now);
    expect(saved.url, 'https://api.example.test/b');
  });

  test('newRequest followed by save creates a second entry', () async {
    final controller = build()..setUrl('https://a.test');
    await controller.save();
    controller
      ..newRequest()
      ..setUrl('https://b.test');
    await controller.save();
    expect(store.saved.map((r) => r.url), ['https://b.test', 'https://a.test']);
  });

  test('open replaces the draft and bumps the revision', () async {
    final controller = build();
    final revision = controller.draftRevision;
    controller.open(
      makeRequest(
        id: 'z',
        method: HttpMethod.delete,
        url: 'https://z.test',
        headers: const [HeaderEntry(id: 'h', name: 'A', value: 'b')],
        body: 'payload',
      ),
    );
    expect(controller.activeId, 'z');
    expect(controller.method, HttpMethod.delete);
    expect(controller.url, 'https://z.test');
    expect(controller.headers.single.name, 'A');
    expect(controller.body, 'payload');
    expect(controller.draftRevision, revision + 1);
  });

  test('delete removes the request and clears the active ID', () async {
    store.saved = [makeRequest(id: 'a'), makeRequest(id: 'b')];
    final controller = build();
    await controller.load();
    controller.open(controller.savedRequests.first);
    await controller.delete('a');
    expect(store.saved.map((r) => r.id), ['b']);
    expect(controller.activeId, isNull);
  });

  test('header rows can be added, edited, and removed', () {
    final controller = build();
    final first = controller.headers.single.id;
    controller
      ..updateHeader(first, name: 'Accept', value: '*/*')
      ..addHeader();
    expect(controller.headers, hasLength(2));
    controller.updateHeader(first, enabled: false);
    expect(controller.headers.first.enabled, isFalse);
    controller
      ..removeHeader(first)
      ..removeHeader(controller.headers.single.id);
    expect(controller.headers, hasLength(1), reason: 'always one blank row');
    expect(controller.headers.single.isBlank, isTrue);
  });

  test('send executes the draft and exposes the outcome', () async {
    late http.Request sent;
    final controller = build(
      client: MockClient((request) async {
        sent = request;
        return http.Response('done', 201);
      }),
    );
    controller
      ..setMethod(HttpMethod.post)
      ..setUrl('https://api.example.test/send')
      ..updateHeader(controller.headers.single.id, name: 'X-A', value: '1')
      ..setBody('body');

    final future = controller.send();
    expect(controller.isSending, isTrue);
    await future;

    expect(controller.isSending, isFalse);
    expect((controller.outcome as ApiResponse).statusCode, 201);
    expect(sent.headers['X-A'], '1');
    expect(sent.body, 'body');
  });

  test('send surfaces validation failures as outcomes', () async {
    final controller = build()..setUrl('mailto:someone@example.test');
    await controller.send();
    expect(
      (controller.outcome as RequestFailure).kind,
      FailureKind.unsupportedScheme,
    );
  });

  test('updateSettings changes executor limits', () {
    final controller = build()
      ..updateSettings(
        timeout: const Duration(seconds: 5),
        maxResponseBytes: 1024,
      );
    expect(controller.timeout, const Duration(seconds: 5));
    expect(controller.maxResponseBytes, 1024);
  });

  test('reports storage failures without throwing', () async {
    store.failSaves = true;
    final controller = build()..setUrl('https://a.test');
    await controller.save();
    expect(controller.storageMessage, isNotNull);
    expect(controller.savedRequests, hasLength(1), reason: 'kept in memory');
  });
}
