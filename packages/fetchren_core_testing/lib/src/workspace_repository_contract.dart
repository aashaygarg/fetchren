import 'package:fetchren_core/fetchren_core.dart';
import 'package:test/test.dart';

import 'tree_builder.dart';

/// Behavior every [WorkspaceRepository] implementation must satisfy.
void runWorkspaceRepositoryContract(
  String name,
  Future<WorkspaceRepository> Function() create,
) {
  group('$name contract', () {
    late WorkspaceRepository repo;
    final tree = TreeBuilder();
    final later = t0.add(const Duration(hours: 1));

    late Workspace workspace;
    late Collection collection;

    setUp(() async {
      repo = await create();
      workspace = tree.workspace(id: 'w');
      collection = tree.collection(workspace, id: 'c');
      await repo.transaction((tx) async {
        await tx.put(workspace);
        await tx.put(collection);
      });
    });

    Future<void> put(WorkspaceEntity entity) =>
        repo.transaction((tx) => tx.put(entity));

    group('reads and writes', () {
      test('round-trips every entity type', () async {
        final folder = tree.folder(collection, id: 'f');
        final request = tree.request(collection, folder: folder, id: 'r');
        await put(folder);
        await put(request);

        expect(await repo.get('w'), isA<Workspace>());
        expect(await repo.get('c'), isA<Collection>());
        final storedFolder = await repo.get('f') as Folder;
        expect(storedFolder.collectionId, 'c');
        final storedRequest = await repo.get('r') as RequestItem;
        expect(storedRequest.folderId, 'f');
        expect(storedRequest.meta, request.meta);
        expect(storedRequest.template, request.template);
        expect(await repo.get('missing'), isNull);
      });

      test(
        'lists workspaces and children ordered by sort key then ID',
        () async {
          final c2 = tree.collection(workspace, id: 'c2', sortKey: 'a');
          await put(c2);
          expect((await repo.children('w')).map((e) => e.id), ['c2', 'c']);

          final f = tree.folder(collection, id: 'f', sortKey: 'm');
          final r1 = tree.request(collection, id: 'r1', sortKey: 'b');
          final r2 = tree.request(collection, id: 'r2', sortKey: 'z');
          final tie = tree.request(collection, id: 'r0', sortKey: 'm');
          for (final e in [f, r1, r2, tie]) {
            await put(e);
          }
          expect((await repo.children('c')).map((e) => e.id), [
            'r1',
            'f',
            'r0',
            'r2',
          ], reason: 'f and r0 share key m; ID breaks the tie');
          expect((await repo.workspaces()).map((e) => e.id), ['w']);
        },
      );

      test(
        'children of a folder are separate from the collection root',
        () async {
          final f = tree.folder(collection, id: 'f');
          final inside = tree.request(collection, folder: f, id: 'in');
          final root = tree.request(collection, id: 'root');
          for (final e in [f, inside, root]) {
            await put(e);
          }
          expect((await repo.children('f')).map((e) => e.id), ['in']);
          expect(
            (await repo.children('c')).map((e) => e.id),
            unorderedEquals(['f', 'root']),
          );
        },
      );
    });

    group('bounded reads', () {
      RequestItem request(
        String id,
        DateTime updatedAt, {
        Folder? folder,
        HttpMethod method = HttpMethod.get,
      }) {
        final r = tree.request(collection, folder: folder, id: id);
        return r.copyWith(
          meta: EntityMeta.create(now: updatedAt, sortKey: 'i', id: id),
          name: 'Name $id',
          template: r.template.copyWith(
            method: method,
            headers: const [HeaderEntry(id: 'h', name: 'X-A', value: '1')],
            body: 'body of $id',
          ),
        );
      }

      Future<List<String>> ids({required int limit, RequestSummary? after}) =>
          repo
              .requestSummaries('c', limit: limit, after: after)
              .then((page) => [for (final s in page) s.id]);

      test('children honours a limit in sort-key order', () async {
        for (final (id, key) in [('a', 'm'), ('b', 'b'), ('c1', 'z')]) {
          await put(tree.request(collection, id: id, sortKey: key));
        }
        expect((await repo.children('c', limit: 2)).map((e) => e.id), [
          'b',
          'a',
        ]);
        expect(await repo.children('c', limit: 10), hasLength(3));
      });

      test('summaries list live requests newest first, ties by ID', () async {
        final folder = tree.folder(collection, id: 'f');
        await put(folder);
        await put(request('old', t0));
        await put(request('new', later, method: HttpMethod.post));
        await put(request('tie-b', t0.add(const Duration(minutes: 1))));
        await put(request('tie-a', t0.add(const Duration(minutes: 1))));
        await put(request('nested', later, folder: folder));
        await put(request('gone', later));
        await repo.transaction((tx) => tx.softDelete('gone', later));

        final page = await repo.requestSummaries('c', limit: 10);
        expect(page.map((s) => s.id), ['new', 'tie-a', 'tie-b', 'old']);
        expect(
          page.first,
          RequestSummary(
            id: 'new',
            name: 'Name new',
            method: HttpMethod.post,
            updatedAt: later,
          ),
        );
        expect(page.first.updatedAt.isUtc, isTrue);
        expect((await repo.requestSummaries('f', limit: 10)).map((s) => s.id), [
          'nested',
        ], reason: 'requests in folders belong to the folder');
        expect(await repo.requestSummaries('missing', limit: 10), isEmpty);
      });

      test('summaries match the full requests they describe', () async {
        await put(request('r', later, method: HttpMethod.delete));
        final summary = (await repo.requestSummaries('c', limit: 1)).single;
        expect(
          summary,
          RequestSummary.of((await repo.get('r'))! as RequestItem),
        );
      });

      test('pages cover every request exactly once, in order', () async {
        await repo.transaction((tx) async {
          for (var i = 0; i < 25; i++) {
            // Pairs share a timestamp so pages split ties.
            final id = 'r${i.toString().padLeft(2, '0')}';
            await tx.put(request(id, t0.add(Duration(minutes: i ~/ 2))));
          }
        });
        final all = await repo.requestSummaries('c', limit: 100);
        expect(all, hasLength(25));
        final paged = <String>[];
        RequestSummary? after;
        while (true) {
          final page = await repo.requestSummaries('c', limit: 4, after: after);
          paged.addAll(page.map((s) => s.id));
          if (page.length < 4) break;
          after = page.last;
        }
        expect(paged, all.map((s) => s.id));
        expect(paged.toSet(), hasLength(25));
      });

      test('paging continues after a request that was deleted', () async {
        await put(request('a', later));
        await put(request('b', t0.add(const Duration(minutes: 30))));
        await put(request('c1', t0));
        final first = await repo.requestSummaries('c', limit: 1);
        await repo.transaction((tx) => tx.softDelete('a', later));
        expect(await ids(limit: 5, after: first.single), ['b', 'c1']);
        expect(await ids(limit: 5), ['b', 'c1']);
      });

      test('reads inside a transaction see its own writes', () async {
        await repo.transaction((tx) async {
          await tx.put(request('r', later));
          expect((await tx.requestSummaries('c', limit: 5)).map((s) => s.id), [
            'r',
          ]);
          expect((await tx.children('c', limit: 1)).single.id, 'r');
          expect(await repo.requestSummaries('c', limit: 5), isEmpty);
        });
      });

      test('limits below 1 are rejected', () async {
        await expectLater(repo.children('c', limit: 0), throwsRangeError);
        await expectLater(
          repo.requestSummaries('c', limit: 0),
          throwsRangeError,
        );
        await expectLater(
          repo.transaction((tx) => tx.requestSummaries('c', limit: -1)),
          throwsRangeError,
        );
      });
    });

    group('versioning', () {
      test('updates require exactly the next version', () async {
        final r = tree.request(collection, id: 'r');
        await put(r);
        final v2 = r.copyWith(meta: r.meta.next(later), name: 'Renamed');
        await put(v2);
        expect((await repo.get('r'))!.name, 'Renamed');
        expect((await repo.get('r'))!.meta.version, 2);

        await expectLater(put(v2), throwsA(isA<StaleWriteException>()));
        final skipped = v2.copyWith(meta: v2.meta.next(later).next(later));
        await expectLater(put(skipped), throwsA(isA<StaleWriteException>()));
        final staleFromV1 = r.copyWith(meta: r.meta.next(later), name: 'Old');
        await expectLater(
          put(staleFromV1),
          throwsA(isA<StaleWriteException>()),
        );
        expect((await repo.get('r'))!.name, 'Renamed');
      });

      test('new entities must start at version 1', () async {
        final r = tree.request(collection, id: 'r');
        await expectLater(
          put(r.withMeta(r.meta.next(later))),
          throwsA(isA<StaleWriteException>()),
        );
      });

      test('createdAt and type are immutable', () async {
        final r = tree.request(collection, id: 'r');
        await put(r);
        final rewritten = r.withMeta(
          EntityMeta(
            id: 'r',
            createdAt: later,
            updatedAt: later,
            version: 2,
            sortKey: 'i',
          ),
        );
        await expectLater(
          put(rewritten),
          throwsA(isA<WorkspaceIntegrityException>()),
        );
        final asFolder = Folder(
          meta: r.meta.next(later),
          workspaceId: 'w',
          collectionId: 'c',
          name: 'F',
        );
        await expectLater(
          put(asFolder),
          throwsA(isA<WorkspaceIntegrityException>()),
        );
      });
    });

    group('integrity', () {
      Matcher integrity() => throwsA(isA<WorkspaceIntegrityException>());

      test('parents must exist and have the right type', () async {
        final orphan = Collection(
          meta: EntityMeta.create(now: t0, sortKey: 'i'),
          workspaceId: 'nope',
          name: 'C',
        );
        await expectLater(put(orphan), integrity());

        final r = tree.request(collection, id: 'r');
        await put(r);
        final underRequest = RequestItem(
          meta: EntityMeta.create(now: t0, sortKey: 'i'),
          workspaceId: 'w',
          collectionId: 'c',
          folderId: 'r',
          name: 'R',
          template: r.template,
        );
        await expectLater(put(underRequest), integrity());
      });

      test('workspace and collection IDs must agree with parents', () async {
        final other = tree.workspace(id: 'w2');
        await put(other);
        final wrongWorkspace = Folder(
          meta: EntityMeta.create(now: t0, sortKey: 'i'),
          workspaceId: 'w2',
          collectionId: 'c',
          name: 'F',
        );
        await expectLater(put(wrongWorkspace), integrity());

        final c2 = tree.collection(workspace, id: 'c2');
        final f2 = tree.folder(c2, id: 'f2');
        await put(c2);
        await put(f2);
        final crossCollection = tree
            .request(collection)
            .copyWith(
              meta: EntityMeta.create(now: t0, sortKey: 'i'),
              folderId: () => 'f2',
            );
        await expectLater(put(crossCollection), integrity());
      });

      test('entities cannot move between workspaces or collections', () async {
        final c2 = tree.collection(workspace, id: 'c2');
        final r = tree.request(collection, id: 'r');
        await put(c2);
        await put(r);
        final moved = RequestItem(
          meta: r.meta.next(later),
          workspaceId: 'w',
          collectionId: 'c2',
          name: r.name,
          template: r.template,
        );
        await expectLater(put(moved), integrity());
      });

      test('folders cannot become their own ancestor', () async {
        final a = tree.folder(collection, id: 'a');
        final b = tree.folder(collection, parent: a, id: 'b');
        await put(a);
        await put(b);
        final cycle = a.copyWith(
          meta: a.meta.next(later),
          parentFolderId: () => 'b',
        );
        await expectLater(put(cycle), integrity());
        final self = a.copyWith(
          meta: a.meta.next(later),
          parentFolderId: () => 'a',
        );
        await expectLater(put(self), integrity());
      });

      test('folders and requests can move within a collection', () async {
        final a = tree.folder(collection, id: 'a');
        final b = tree.folder(collection, id: 'b');
        final r = tree.request(collection, folder: a, id: 'r');
        for (final e in [a, b, r]) {
          await put(e);
        }
        await put(
          b.copyWith(meta: b.meta.next(later), parentFolderId: () => 'a'),
        );
        await put(r.copyWith(meta: r.meta.next(later), folderId: () => 'b'));
        expect((await repo.children('a')).map((e) => e.id), ['b']);
        expect((await repo.children('b')).map((e) => e.id), ['r']);
      });

      test('tombstones can only be written with softDelete', () async {
        final r = tree.request(collection, id: 'r');
        await put(r);
        await expectLater(put(r.withMeta(r.meta.deleted(later))), integrity());
      });
    });

    group('soft delete', () {
      late Folder folder;
      late Folder nested;
      late RequestItem deep;
      late RequestItem sibling;

      setUp(() async {
        folder = tree.folder(collection, id: 'f');
        nested = tree.folder(collection, parent: folder, id: 'f2');
        deep = tree.request(collection, folder: nested, id: 'deep');
        sibling = tree.request(collection, id: 'sibling');
        await repo.transaction((tx) async {
          for (final e in [folder, nested, deep, sibling]) {
            await tx.put(e);
          }
        });
      });

      test('cascades to live descendants as tombstones', () async {
        final count = await repo.transaction((tx) => tx.softDelete('f', later));
        expect(count, 3);
        for (final id in ['f', 'f2', 'deep']) {
          final e = (await repo.get(id))!;
          expect(e.meta.isDeleted, isTrue, reason: id);
          expect(e.meta.deletedAt, later);
          expect(e.meta.version, 2);
        }
        expect((await repo.get('sibling'))!.meta.isDeleted, isFalse);
        expect((await repo.children('c')).map((e) => e.id), ['sibling']);
        expect(
          (await repo.children('c', includeDeleted: true)).map((e) => e.id),
          unorderedEquals(['f', 'sibling']),
        );
      });

      test('deleting a workspace tombstones the whole tree', () async {
        final count = await repo.transaction((tx) => tx.softDelete('w', later));
        expect(count, 6);
        expect(await repo.workspaces(), isEmpty);
        expect(await repo.workspaces(includeDeleted: true), hasLength(1));
      });

      test('is idempotent and reports missing IDs', () async {
        await repo.transaction((tx) => tx.softDelete('f', later));
        expect(await repo.transaction((tx) => tx.softDelete('f', later)), 0);
        await expectLater(
          repo.transaction((tx) => tx.softDelete('missing', later)),
          throwsA(isA<EntityNotFoundException>()),
        );
      });

      test('live children cannot be added under a deleted parent', () async {
        await repo.transaction((tx) => tx.softDelete('f', later));
        await expectLater(
          put(tree.request(collection, folder: folder)),
          throwsA(isA<WorkspaceIntegrityException>()),
        );
      });

      test(
        'restoring writes a live revision; descendants stay deleted',
        () async {
          await repo.transaction((tx) => tx.softDelete('f', later));
          final tombstone = (await repo.get('f'))! as Folder;
          final restored = Folder(
            meta: EntityMeta(
              id: 'f',
              createdAt: tombstone.meta.createdAt,
              updatedAt: later,
              version: tombstone.meta.version + 1,
              sortKey: tombstone.meta.sortKey,
            ),
            workspaceId: 'w',
            collectionId: 'c',
            name: tombstone.name,
          );
          await put(restored);
          expect((await repo.get('f'))!.meta.isDeleted, isFalse);
          expect((await repo.get('f2'))!.meta.isDeleted, isTrue);
        },
      );
    });

    group('transactions', () {
      test('roll back every write when the action throws', () async {
        final r = tree.request(collection, id: 'r');
        await expectLater(
          repo.transaction((tx) async {
            await tx.put(r);
            await tx.softDelete('c', later);
            throw StateError('boom');
          }),
          throwsStateError,
        );
        expect(await repo.get('r'), isNull);
        expect((await repo.get('c'))!.meta.isDeleted, isFalse);
      });

      test('roll back when a later write violates a rule', () async {
        final good = tree.request(collection, id: 'good');
        final bad = tree
            .request(collection, id: 'bad')
            .copyWith(
              meta: EntityMeta.create(now: t0, sortKey: 'i', id: 'bad'),
              folderId: () => 'missing',
            );
        await expectLater(
          repo.transaction((tx) async {
            await tx.put(good);
            await tx.put(bad);
          }),
          throwsA(isA<WorkspaceIntegrityException>()),
        );
        expect(await repo.get('good'), isNull);
      });

      test('reads inside a transaction see its own writes only', () async {
        final r = tree.request(collection, id: 'r');
        await repo.transaction((tx) async {
          await tx.put(r);
          expect(await tx.get('r'), isNotNull);
          expect(await repo.get('r'), isNull, reason: 'not yet committed');
          expect((await tx.children('c')).map((e) => e.id), ['r']);
        });
        expect(await repo.get('r'), isNotNull);
      });

      test('returns the action result', () async {
        expect(await repo.transaction((tx) async => 42), 42);
      });

      test('concurrent transactions are serialized', () async {
        final r = tree.request(collection, id: 'r');
        await put(r);
        Future<void> rename(String name) => repo.transaction((tx) async {
          final current = (await tx.get('r'))! as RequestItem;
          await Future<void>.delayed(Duration.zero);
          await tx.put(
            current.copyWith(meta: current.meta.next(later), name: name),
          );
        });
        await Future.wait([rename('A'), rename('B'), rename('C')]);
        final stored = (await repo.get('r'))!;
        expect(stored.meta.version, 4, reason: 'no lost update');
        expect(stored.name, 'C');
      });

      test('a failed transaction does not block later ones', () async {
        await expectLater(
          repo.transaction<void>((tx) async => throw StateError('x')),
          throwsStateError,
        );
        expect(await repo.transaction((tx) async => 'ok'), 'ok');
      });

      test('nested transactions are rejected', () async {
        await expectLater(
          repo.transaction((tx) => repo.transaction((inner) async {})),
          throwsStateError,
        );
      });

      test('the writer cannot be used after the transaction ends', () async {
        late WorkspaceWriter escaped;
        await repo.transaction((tx) async => escaped = tx);
        await expectLater(escaped.get('w'), throwsStateError);
        await expectLater(
          escaped.put(tree.request(collection)),
          throwsStateError,
        );
      });
    });
  });
}
