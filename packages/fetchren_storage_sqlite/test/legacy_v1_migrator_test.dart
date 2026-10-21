import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fetchren_core/fetchren_core.dart';
import 'package:fetchren_storage_sqlite/fetchren_storage_sqlite.dart';
import 'package:test/test.dart';

final DateTime t0 = DateTime.utc(2026, 10, 21, 12);

Map<String, Object?> legacyJson(
  String id, {
  String? name,
  String method = 'GET',
  String? url,
  List<Map<String, Object?>> headers = const [],
  String body = '',
  DateTime? createdAt,
  DateTime? updatedAt,
}) => {
  'id': id,
  'name': name ?? 'https://$id.test',
  'method': method,
  'url': url ?? 'https://$id.test',
  'headers': headers,
  'body': body,
  'createdAt': (createdAt ?? t0).toIso8601String(),
  'updatedAt': (updatedAt ?? t0).toIso8601String(),
};

void main() {
  late Directory dir;
  late File legacy;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('fetchren_migration');
    legacy = File('${dir.path}/requests.json');
  });

  tearDown(() => dir.delete(recursive: true));

  Future<void> writeLegacy(List<Object?> requests) =>
      legacy.writeAsString(jsonEncode({'version': 1, 'requests': requests}));

  Future<LocalWorkspace> open({
    FutureOr<void> Function(MigrationStage)? onStage,
  }) =>
      openLocalWorkspace(dir.path, clock: () => t0, onMigrationStage: onStage);

  Future<List<RequestItem>> requestsIn(LocalWorkspace local) async => [
    for (final e in await local.repository.children(local.collection.id))
      e as RequestItem,
  ];

  List<String> archived() => [
    for (final f in dir.listSync().whereType<File>())
      if (f.uri.pathSegments.last.startsWith('requests.v1-migrated-'))
        f.uri.pathSegments.last,
  ];

  group('successful migration', () {
    test('imports every record with IDs, contents, and timestamps', () async {
      final created = DateTime.utc(2025, 1, 2, 3, 4, 5, 6);
      final updated = DateTime.utc(2025, 2, 3, 4, 5, 6, 7);
      await writeLegacy([
        legacyJson(
          'a',
          name: 'Create item',
          method: 'POST',
          url: 'https://api.example.test/items',
          headers: [
            {'id': 'h1', 'name': 'Accept', 'value': '*/*', 'enabled': true},
            {'id': 'h2', 'name': 'X-Off', 'value': 'v', 'enabled': false},
          ],
          body: '{"n":1}',
          createdAt: created,
          updatedAt: updated,
        ),
        legacyJson('b', updatedAt: DateTime.utc(2024)),
      ]);

      final local = await open();
      addTearDown(local.close);

      expect(local.isPersistent, isTrue);
      expect(local.migration.outcome, LegacyMigrationOutcome.completed);
      expect(local.migration.marker!.imported, 2);
      final items = await requestsIn(local);
      expect(items.map((r) => r.id), ['a', 'b']);
      final a = items.first;
      expect(a.name, 'Create item');
      expect(a.meta.createdAt, created);
      expect(a.meta.updatedAt, updated);
      expect(a.meta.version, 1);
      expect(a.template.method, HttpMethod.post);
      expect(a.template.url, 'https://api.example.test/items');
      expect(a.template.body, '{"n":1}');
      expect(a.template.headers.map((h) => (h.id, h.enabled)), [
        ('h1', true),
        ('h2', false),
      ]);
    });

    test('renames, never deletes, the original after completion', () async {
      await writeLegacy([legacyJson('a')]);
      final original = await legacy.readAsString();
      final local = await open();
      addTearDown(local.close);

      expect(legacy.existsSync(), isFalse);
      final kept = archived();
      expect(kept, hasLength(1));
      expect(await File('${dir.path}/${kept.single}').readAsString(), original);
      expect(local.migration.marker!.archivedTo, endsWith(kept.single));
    });

    test('repeated startups do not import again or duplicate', () async {
      await writeLegacy([legacyJson('a'), legacyJson('b')]);
      (await open()).close();
      for (var i = 0; i < 3; i++) {
        final local = await open();
        expect(local.migration.outcome, LegacyMigrationOutcome.completed);
        expect(await requestsIn(local), hasLength(2));
        await local.close();
      }
      expect(archived(), hasLength(1));
    });

    test('a fresh install has nothing to migrate', () async {
      final local = await open();
      addTearDown(local.close);
      expect(local.migration.outcome, LegacyMigrationOutcome.notNeeded);
      expect(await requestsIn(local), isEmpty);
    });

    test('an empty v1 store completes with zero records', () async {
      await writeLegacy([]);
      final local = await open();
      addTearDown(local.close);
      expect(local.migration.outcome, LegacyMigrationOutcome.completed);
      expect(local.migration.marker!.imported, 0);
    });

    test('automatic repairs are recorded in the marker', () async {
      await writeLegacy([
        legacyJson('blank', name: ' '),
        legacyJson(
          'skewed',
          createdAt: DateTime.utc(2026, 5),
          updatedAt: DateTime.utc(2026, 4),
        ),
      ]);
      final local = await open();
      addTearDown(local.close);
      expect(local.migration.warnings, hasLength(2));
      final reopened = await local.repository.get('blank');
      expect(reopened!.name, untitledRequestName);
    });
  });

  group('invalid input fails safely', () {
    Future<void> expectFailedAndUntouched(String contents) async {
      await legacy.writeAsString(contents);
      final local = await open();
      addTearDown(local.close);
      expect(local.migration.outcome, LegacyMigrationOutcome.failed);
      expect(local.migration.errors, isNotEmpty);
      expect(await requestsIn(local), isEmpty, reason: 'nothing imported');
      expect(await legacy.readAsString(), contents, reason: 'file untouched');
      expect(archived(), isEmpty);
    }

    test('corrupt JSON', () => expectFailedAndUntouched('{"version": 1, "re'));

    test('duplicate IDs', () async {
      await expectFailedAndUntouched(
        jsonEncode({
          'version': 1,
          'requests': [legacyJson('dup'), legacyJson('dup')],
        }),
      );
    });

    test(
      'a malformed record fails the whole import, naming the entry',
      () async {
        await expectFailedAndUntouched(
          jsonEncode({
            'version': 1,
            'requests': [
              legacyJson('ok'),
              {...legacyJson('bad'), 'method': 'TRACE'},
            ],
          }),
        );
      },
    );

    test(
      'a failure is retried on every startup and recovers once fixed',
      () async {
        await legacy.writeAsString('{broken');
        var local = await open();
        expect(local.migration.marker!.attempts, 1);
        await local.close();
        local = await open();
        expect(local.migration.outcome, LegacyMigrationOutcome.failed);
        expect(local.migration.marker!.attempts, 2);
        await local.close();

        await writeLegacy([legacyJson('fixed')]);
        local = await open();
        addTearDown(local.close);
        expect(local.migration.outcome, LegacyMigrationOutcome.completed);
        expect(local.migration.marker!.attempts, 3);
        expect((await requestsIn(local)).single.id, 'fixed');
      },
    );

    test('removing the file after a failure marks it skipped', () async {
      await legacy.writeAsString('{broken');
      (await open()).close();
      await legacy.delete();
      final local = await open();
      addTearDown(local.close);
      expect(local.migration.outcome, LegacyMigrationOutcome.skipped);
    });

    test('requests saved while the import was failing are kept', () async {
      await legacy.writeAsString('{broken');
      var local = await open();
      final c = local.collection;
      await local.repository.transaction(
        (tx) => tx.put(
          RequestItem(
            meta: EntityMeta.create(now: t0, sortKey: 'i', id: 'new'),
            workspaceId: c.workspaceId,
            collectionId: c.id,
            name: 'new',
            template: RequestTemplate(method: HttpMethod.get, url: 'https://n'),
          ),
        ),
      );
      await local.close();

      await writeLegacy([legacyJson('old')]);
      local = await open();
      addTearDown(local.close);
      expect(local.collection.id, c.id, reason: 'same default collection');
      expect(
        (await requestsIn(local)).map((r) => r.id),
        unorderedEquals(['new', 'old']),
      );
      expect(await local.repository.workspaces(), hasLength(1));
    });

    test(
      'an ID collision with an existing record fails without changes',
      () async {
        await legacy.writeAsString('{broken');
        var local = await open();
        final c = local.collection;
        await local.repository.transaction(
          (tx) => tx.put(
            RequestItem(
              meta: EntityMeta.create(now: t0, sortKey: 'i', id: 'clash'),
              workspaceId: c.workspaceId,
              collectionId: c.id,
              name: 'mine',
              template: RequestTemplate(
                method: HttpMethod.get,
                url: 'https://m',
              ),
            ),
          ),
        );
        await local.close();

        await writeLegacy([legacyJson('other'), legacyJson('clash')]);
        local = await open();
        addTearDown(local.close);
        expect(local.migration.outcome, LegacyMigrationOutcome.failed);
        expect((await requestsIn(local)).single.name, 'mine');
        expect(legacy.existsSync(), isTrue);
      },
    );
  });

  group('interruption at each stage (in-process)', () {
    test(
      'an instance overtaken by another never downgrades completion',
      () async {
        await writeLegacy([legacyJson('a'), legacyJson('b')]);
        LocalWorkspace? first;
        // B pauses after marking in-progress while A runs to completion.
        final second = await open(
          onStage: (stage) async {
            if (stage == MigrationStage.markedInProgress && first == null) {
              first = await open();
            }
          },
        );
        addTearDown(() async {
          await first?.close();
          await second.close();
        });

        expect(first!.migration.outcome, LegacyMigrationOutcome.completed);
        expect(second.migration.outcome, LegacyMigrationOutcome.completed);
        final again = await open();
        addTearDown(again.close);
        expect(again.migration.outcome, LegacyMigrationOutcome.completed);
        expect(again.migration.marker!.state, LegacyMigrationState.completed);
        expect(again.migration.marker!.imported, 2);
        expect(await requestsIn(again), hasLength(2));
        expect(archived(), hasLength(1));
      },
    );
    test('concurrent startups all report completion, import once', () async {
      await writeLegacy([legacyJson('a'), legacyJson('b')]);
      for (var round = 0; round < 10; round++) {
        final opened = await Future.wait([for (var i = 0; i < 4; i++) open()]);
        for (final local in opened) {
          expect(
            local.migration.outcome,
            LegacyMigrationOutcome.completed,
            reason: 'round $round: ${local.migration.errors}',
          );
          await local.close();
        }
        if (round == 0) {
          final check = await open();
          expect(check.migration.marker!.state, LegacyMigrationState.completed);
          expect(check.migration.marker!.imported, 2);
          expect(await requestsIn(check), hasLength(2));
          await check.close();
        }
      }
      expect(archived(), hasLength(1));
    });
    for (final stage in MigrationStage.values) {
      test('after ${stage.name}: retry completes exactly once', () async {
        await writeLegacy([legacyJson('a'), legacyJson('b')]);
        await expectLater(
          open(
            onStage: (s) {
              if (s == stage) throw _SimulatedCrash();
            },
          ),
          throwsA(isA<_SimulatedCrash>()),
        );

        final local = await open();
        addTearDown(local.close);
        expect(local.migration.outcome, LegacyMigrationOutcome.completed);
        expect(
          (await requestsIn(local)).map((r) => r.id),
          unorderedEquals(['a', 'b']),
        );
        expect(legacy.existsSync(), isFalse);
        expect(archived(), hasLength(1));
      });
    }

    test('a crash before commit leaves the marker in progress', () async {
      await writeLegacy([legacyJson('a')]);
      await expectLater(
        open(
          onStage: (s) {
            if (s == MigrationStage.recordsWrittenBeforeCommit) {
              throw _SimulatedCrash();
            }
          },
        ),
        throwsA(isA<_SimulatedCrash>()),
      );
      final repo = SqliteWorkspaceRepository.open(
        '${dir.path}/$workspaceDatabaseFileName',
      );
      addTearDown(repo.close);
      final marker = jsonDecode(
        (await repo.readMeta(legacyMigrationMarkerKey))!,
      );
      expect(marker['state'], 'inProgress');
      expect(await repo.get('a'), isNull, reason: 'rolled back');
      expect(legacy.existsSync(), isTrue);
    });
  });

  group('separate OS processes', () {
    late Directory bundle;
    late String workerExe;

    // Concurrent `dart run` calls race on re-bundling native assets, so the
    // worker is compiled once and launched directly.
    setUpAll(() async {
      bundle = await Directory.systemTemp.createTemp('fetchren_worker');
      final build = await Process.run(Platform.resolvedExecutable, [
        'build',
        'cli',
        '-t',
        'test/support/worker.dart',
        '-o',
        bundle.path,
      ]);
      expect(build.exitCode, 0, reason: '${build.stdout}${build.stderr}');
      workerExe =
          '${bundle.path}/bundle/bin/worker${Platform.isWindows ? '.exe' : ''}';
    });

    tearDownAll(() => bundle.delete(recursive: true));

    Future<ProcessResult> worker(List<String> args) =>
        Process.run(workerExe, args);

    for (final stage in MigrationStage.values) {
      test(
        'process killed after ${stage.name}: next startup recovers',
        () async {
          await writeLegacy([
            legacyJson('a'),
            legacyJson('b'),
            legacyJson('c'),
          ]);
          final crashed = await worker([
            'crash-migration',
            dir.path,
            stage.name,
          ]);
          expect(crashed.exitCode, 9, reason: '${crashed.stderr}');

          final local = await open();
          addTearDown(local.close);
          expect(local.migration.outcome, LegacyMigrationOutcome.completed);
          expect(
            (await requestsIn(local)).map((r) => r.id),
            unorderedEquals(['a', 'b', 'c']),
          );
          expect(archived(), hasLength(1));
        },
        timeout: const Timeout(Duration(minutes: 2)),
      );
    }

    test('simultaneous first launches all report completion', () async {
      await writeLegacy([for (var i = 0; i < 20; i++) legacyJson('r$i')]);
      final results = await Future.wait([
        for (var i = 0; i < 4; i++) worker(['open', dir.path]),
      ]);
      for (final r in results) {
        expect(r.exitCode, 0, reason: '${r.stderr}');
        expect('${r.stdout}'.trim(), 'completed');
      }
      final local = await open();
      addTearDown(local.close);
      expect(local.migration.marker!.state, LegacyMigrationState.completed);
      expect(local.migration.marker!.imported, 20);
      expect(await requestsIn(local), hasLength(20));
      expect(archived(), hasLength(1));
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('a process killed mid-transaction commits nothing', () async {
      final result = await worker(['crash-mid-transaction', dir.path]);
      expect(result.exitCode, 9, reason: '${result.stderr}');
      final local = await open();
      addTearDown(local.close);
      expect(await local.repository.get('never-committed'), isNull);
      expect(await requestsIn(local), isEmpty);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('two processes writing concurrently lose no updates', () async {
      await writeLegacy([legacyJson('legacy')]);
      final results = await Future.wait([
        worker(['write', dir.path, 'p1', '25']),
        worker(['write', dir.path, 'p2', '25']),
      ]);
      for (final r in results) {
        expect(r.exitCode, 0, reason: '${r.stderr}');
      }
      final local = await open();
      addTearDown(local.close);
      final ids = (await requestsIn(local)).map((r) => r.id).toSet();
      expect(ids, hasLength(52), reason: '25 + 25 + shared + legacy');
      expect(ids, containsAll(['legacy', 'shared', 'p1-0', 'p2-24']));
      final shared = (await local.repository.get('shared'))!;
      expect(shared.meta.version, 50, reason: 'every increment kept');
      expect(await local.repository.workspaces(), hasLength(1));
      expect(archived(), hasLength(1), reason: 'migrated exactly once');
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}

class _SimulatedCrash extends Error {}
