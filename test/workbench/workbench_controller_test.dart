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
      store = await FakeWorkspaceRepository.create([
        (c) => makeItem(c, id: 'other', url: 'https://b.test'),
      ]);
      final pending = Completer<http.Response>();
      final controller = build(client: MockClient((_) => pending.future))
        ..setUrl('https://a.test');
      final sending = controller.send();
      await controller.open('other');
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
    expect(controller.savedRequests.map((r) => r.name), [
      'https://b.test',
      'https://a.test',
    ]);
  });

  test('new requests sort before requests not yet loaded', () async {
    store = await FakeWorkspaceRepository.create([
      for (var i = 0; i < WorkbenchController.pageSize + 5; i++)
        (c) => makeItem(
          c,
          id: 'r$i',
          updatedAt: fixedTime.subtract(Duration(minutes: i)),
          sortKey: i == WorkbenchController.pageSize + 4 ? 'b' : 'i',
        ),
    ]);
    final controller = build();
    await controller.load();
    expect(
      controller.savedRequests.map((r) => r.id),
      isNot(contains('r104')),
      reason: 'the lowest sort key is beyond the first page',
    );
    controller.setUrl('https://new.test');
    await controller.save();
    final children = await store.children(store.collection.id);
    expect(children.first.id, controller.activeId);
    expect(children[1].id, 'r104');
  });

  test('load reads one page; loadMore appends the rest once', () async {
    const total = WorkbenchController.pageSize * 2 + 10;
    store = await FakeWorkspaceRepository.create([
      for (var i = 0; i < total; i++)
        (c) => makeItem(
          c,
          id: 'r${i.toString().padLeft(3, '0')}',
          // Pairs share a timestamp so pages split ties.
          updatedAt: fixedTime.subtract(Duration(minutes: i ~/ 2)),
        ),
    ]);
    final controller = build();
    await controller.load();
    expect(controller.savedRequests, hasLength(WorkbenchController.pageSize));
    expect(controller.hasMoreSaved, isTrue);

    await Future.wait([controller.loadMore(), controller.loadMore()]);
    expect(store.summaryReads, 2, reason: 'concurrent calls read once');
    await controller.loadMore();
    expect(controller.hasMoreSaved, isFalse);
    await controller.loadMore();
    expect(store.summaryReads, 3, reason: 'nothing left to read');

    final ids = controller.savedRequests.map((r) => r.id).toList();
    expect(ids, hasLength(total));
    expect(ids, [
      for (var i = 0; i < total; i++) 'r${i.toString().padLeft(3, '0')}',
    ]);
  });

  test('loadMore skips requests already shown after a save', () async {
    store = await FakeWorkspaceRepository.create([
      for (var i = 0; i < WorkbenchController.pageSize + 1; i++)
        (c) => makeItem(
          c,
          id: 'r${i.toString().padLeft(3, '0')}',
          updatedAt: fixedTime.subtract(Duration(minutes: i)),
        ),
    ]);
    final controller = build();
    await controller.load();
    // With the clock set back, the new request is shown first but is stored
    // after the loaded page, so the next page returns it again.
    now = fixedTime.subtract(const Duration(days: 1));
    controller.setUrl('https://clock-skew.test');
    await controller.save();
    await controller.loadMore();
    final ids = controller.savedRequests.map((r) => r.id).toList();
    expect(ids.first, controller.activeId);
    expect(ids.toSet(), hasLength(ids.length));
    expect(ids, hasLength(WorkbenchController.pageSize + 2));
  });

  test('a failed loadMore stops paging and is reported', () async {
    store = await FakeWorkspaceRepository.create([
      for (var i = 0; i < WorkbenchController.pageSize; i++)
        (c) => makeItem(c, id: 'r$i'),
    ]);
    final controller = build();
    await controller.load();
    expect(controller.hasMoreSaved, isTrue);
    store.failLoads = true;
    await controller.loadMore();
    expect(controller.hasMoreSaved, isFalse);
    expect(controller.storageMessage, contains('could not be loaded'));
    expect(controller.savedRequests, hasLength(WorkbenchController.pageSize));
  });

  test('open replaces the draft and bumps the revision', () async {
    store = await FakeWorkspaceRepository.create([
      (c) => makeItem(
        c,
        id: 'z',
        method: HttpMethod.delete,
        url: 'https://z.test',
        headers: const [HeaderEntry(id: 'h', name: 'A', value: 'b')],
        body: 'payload',
      ),
    ]);
    final controller = build();
    final revision = controller.draftRevision;
    await controller.open('z');
    expect(controller.activeId, 'z');
    expect(controller.method, HttpMethod.delete);
    expect(controller.url, 'https://z.test');
    expect(controller.headers.single.name, 'A');
    expect(controller.body, 'payload');
    expect(controller.draftRevision, revision + 1);
  });

  test('only the last navigation applies', () async {
    store = await FakeWorkspaceRepository.create([
      (c) => makeItem(c, id: 'a', url: 'https://a.test'),
      (c) => makeItem(c, id: 'b', url: 'https://b.test'),
    ]);
    final controller = build();
    final first = controller.open('a');
    await controller.open('b');
    await first;
    expect(controller.activeId, 'b');
    expect(controller.url, 'https://b.test');

    final opening = controller.open('a');
    controller.newRequest();
    await opening;
    expect(controller.activeId, isNull);
    expect(controller.url, isEmpty);
  });

  test('opening a request deleted elsewhere drops it from the list', () async {
    store = await FakeWorkspaceRepository.create([
      (c) => makeItem(c, id: 'a'),
      (c) => makeItem(c, id: 'b'),
    ]);
    final controller = build();
    await controller.load();
    await store.transaction((tx) => tx.softDelete('a', now));
    controller.setUrl('https://draft.test');
    await controller.open('a');
    expect(controller.savedRequests.map((r) => r.id), ['b']);
    expect(controller.storageMessage, contains('deleted in another'));
    expect(controller.activeId, isNull);
    expect(controller.url, 'https://draft.test', reason: 'draft kept');

    await controller.open('never-existed');
    expect(controller.activeId, isNull);
  });

  test('a failed open is reported and keeps the draft', () async {
    store = await FakeWorkspaceRepository.create([(c) => makeItem(c, id: 'a')]);
    final controller = build()..setUrl('https://draft.test');
    store.failLoads = true;
    await controller.open('a');
    expect(controller.storageMessage, contains('could not be opened'));
    expect(controller.url, 'https://draft.test');

    final stale = controller.open('a');
    controller.newRequest();
    await stale;
    expect(controller.storageMessage, contains('could not be opened'));
  });

  test('open waits for a save that has not committed yet', () async {
    final controller = build()..setUrl('https://pending.test');
    store.holdSaves = Completer<void>();
    final saving = controller.save();
    final id = controller.activeId!;
    controller.newRequest();
    final opening = controller.open(id);
    await Future<void>.delayed(Duration.zero);
    store.holdSaves!.complete();
    await saving;
    await opening;
    expect(controller.activeId, id);
    expect(controller.url, 'https://pending.test');
    expect(controller.storageMessage, isNull);
  });

  test('session-only requests can be reopened until deleted', () async {
    final controller = build(persistenceAvailable: false)
      ..setUrl('https://session.test');
    await controller.save();
    final id = controller.activeId!;
    controller.newRequest();
    await controller.open(id);
    expect(controller.url, 'https://session.test');
    expect(store.commits, 0);

    await controller.delete(id);
    await controller.open(id);
    expect(controller.activeId, isNull);
    expect(controller.savedRequests, isEmpty);
  });

  test('delete tombstones the request and clears the active ID', () async {
    store = await FakeWorkspaceRepository.create([
      (c) => makeItem(c, id: 'a'),
      (c) => makeItem(c, id: 'b'),
    ]);
    final controller = build();
    await controller.load();
    await controller.open('a');
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
      await controller.open(controller.savedRequests.single.id);

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
      final stored = (await store.stored()).single;
      expect(stored.template.url, 'https://other-window.test');
      expect(
        controller.savedRequests.single,
        RequestSummary.of(stored),
        reason: 'list reloaded from storage',
      );
      expect(controller.url, 'https://mine.test', reason: 'draft kept');

      // Saving again deliberately replaces the other window's version.
      await controller.save();
      expect(controller.storageMessage, isNull);
      final replaced = (await store.stored()).single;
      expect(replaced.template.url, 'https://mine.test');
      expect(replaced.meta.version, stored.meta.version + 1);
    },
  );

  test(
    'after a conflict on a request deleted elsewhere, saving creates a new one',
    () async {
      store = await FakeWorkspaceRepository.create([
        (c) => makeItem(c, id: 'a'),
      ]);
      final controller = build();
      await controller.load();
      await controller.open('a');
      await store.transaction((tx) => tx.softDelete('a', now));
      await controller.save();
      expect(controller.storageMessage, contains('another FetchRen window'));
      expect(controller.activeId, isNull);
      expect(controller.savedRequests, isEmpty);
      await controller.save();
      expect((await store.stored()).single.id, isNot('a'));
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
