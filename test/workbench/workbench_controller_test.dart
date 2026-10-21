import 'dart:async';

import 'package:fetchren/src/http/request_executor.dart';
import 'package:fetchren/src/http/request_outcome.dart';
import 'package:fetchren/src/workbench/workbench_controller.dart';
import 'package:fetchren_core/fetchren_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../support/fakes.dart';

void main() {
  late FakeWorkspaceRepository store;
  late DateTime now;

  WorkbenchController build({
    http.Client? client,
    bool persistenceAvailable = true,
    String? startupMessage,
  }) => WorkbenchController(
    executor: RequestExecutor(
      client ?? MockClient((_) async => http.Response('{}', 200)),
    ),
    repository: store,
    collection: store.collection,
    clock: () => now,
    persistenceAvailable: persistenceAvailable,
    startupMessage: startupMessage,
  );

  setUp(() async {
    store = await FakeWorkspaceRepository.create();
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
      controller.open(
        makeItem(store.collection, id: 'other', url: 'https://b.test'),
      );
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
    expect(store.commits, 0);
    expect(controller.storageMessage, contains('Saving is disabled'));
  });

  test('a startup problem disables saving and is shown', () async {
    final controller = build(
      persistenceAvailable: false,
      startupMessage: 'Database is from a newer FetchRen.',
    );
    await controller.load();
    controller.setUrl('https://a.test');
    await controller.save();
    expect(store.commits, 0);
    expect(controller.storageMessage, 'Database is from a newer FetchRen.');
    expect(controller.savedRequests, hasLength(1), reason: 'session only');
  });

  test('load lists saved requests newest first', () async {
    store = await FakeWorkspaceRepository.create([
      (c) => makeItem(c, id: 'old', updatedAt: DateTime.utc(2026, 1)),
      (c) => makeItem(c, id: 'new', updatedAt: DateTime.utc(2026, 3)),
    ]);
    final controller = build();
    expect(controller.isLoaded, isFalse);
    await controller.load();
    expect(controller.isLoaded, isTrue);
    expect(controller.savedRequests.map((r) => r.id), ['new', 'old']);
  });

  test('save creates a request with a stable ID and timestamps', () async {
    final controller = build()
      ..setMethod(HttpMethod.post)
      ..setUrl('https://api.example.test/a')
      ..setBody('x');
    await controller.save();

    final saved = (await store.stored()).single;
    expect(saved.id, matches(RegExp(r'^[0-9a-f]{32}$')));
    expect(saved.meta.createdAt, now);
    expect(saved.meta.updatedAt, now);
    expect(saved.meta.version, 1);
    expect(saved.template.method, HttpMethod.post);
    expect(saved.template.body, 'x');
    expect(saved.name, 'https://api.example.test/a');
    expect(saved.collectionId, store.collection.id);
    expect(controller.activeId, saved.id);
    expect(controller.storageMessage, isNull);
  });

  test(
    'saving again updates in place, bumps version, keeps createdAt',
    () async {
      final controller = build()..setUrl('https://api.example.test/a');
      await controller.save();
      final id = controller.activeId;
      final created = now;

      now = now.add(const Duration(minutes: 5));
      controller.setUrl('https://api.example.test/b');
      await controller.save();

      final saved = (await store.stored()).single;
      expect(saved.id, id);
      expect(saved.meta.version, 2);
      expect(saved.meta.createdAt, created);
      expect(saved.meta.updatedAt, now);
      expect(saved.template.url, 'https://api.example.test/b');
    },
  );

  test('newRequest followed by save creates a second entry first', () async {
    final controller = build()..setUrl('https://a.test');
    await controller.save();
    now = now.add(const Duration(seconds: 1));
    controller
      ..newRequest()
      ..setUrl('https://b.test');
    await controller.save();
    expect((await store.stored()).map((r) => r.template.url), [
      'https://b.test',
      'https://a.test',
    ], reason: 'stored order matches the newest-first list');
    expect(controller.savedRequests.map((r) => r.template.url), [
      'https://b.test',
      'https://a.test',
    ]);
  });

  test('open replaces the draft and bumps the revision', () async {
    final controller = build();
    final revision = controller.draftRevision;
    controller.open(
      makeItem(
        store.collection,
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

  test('delete tombstones the request and clears the active ID', () async {
    store = await FakeWorkspaceRepository.create([
      (c) => makeItem(c, id: 'a'),
      (c) => makeItem(c, id: 'b'),
    ]);
    final controller = build();
    await controller.load();
    controller.open(controller.savedRequests.firstWhere((r) => r.id == 'a'));
    await controller.delete('a');
    expect((await store.stored()).map((r) => r.id), ['b']);
    expect((await store.get('a'))!.meta.isDeleted, isTrue);
    expect(controller.activeId, isNull);
  });

  test(
    'a save that conflicts with another window is not overwritten',
    () async {
      store = await FakeWorkspaceRepository.create([
        (c) => makeItem(c, id: 'a', url: 'https://original.test'),
      ]);
      final controller = build();
      await controller.load();
      controller.open(controller.savedRequests.single);

      final other = (await store.get('a'))! as RequestItem;
      await store.transaction(
        (tx) => tx.put(
          other.copyWith(
            meta: other.meta.next(now),
            template: other.template.copyWith(url: 'https://other-window.test'),
          ),
        ),
      );

      controller.setUrl('https://mine.test');
      await controller.save();
      expect(controller.storageMessage, contains('another FetchRen window'));
      expect(
        (await store.stored()).single.template.url,
        'https://other-window.test',
      );
      expect(
        controller.savedRequests.single.template.url,
        'https://other-window.test',
        reason: 'list reloaded from storage',
      );
      expect(controller.url, 'https://mine.test', reason: 'draft kept');
    },
  );

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

  test('a failed save is reported and the list shows what is stored', () async {
    store.failSaves = true;
    final controller = build()..setUrl('https://a.test');
    await controller.save();
    expect(controller.storageMessage, 'Requests could not be saved to disk.');
    expect(controller.savedRequests, isEmpty);
    expect(controller.url, 'https://a.test', reason: 'draft kept');
  });
}
