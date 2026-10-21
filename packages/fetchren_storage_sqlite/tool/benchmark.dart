// Times the repository operations the app performs on the UI isolate, for
// growing workspace sizes. Writes only to a temporary directory.
//   dart run tool/benchmark.dart [sizes...]   (default: 100 1000 10000 50000)
import 'dart:io';

import 'package:fetchren_core/fetchren_core.dart';
import 'package:fetchren_storage_sqlite/fetchren_storage_sqlite.dart';

const int _runs = 20;
final DateTime _now = DateTime.utc(2026, 10, 21);

Future<void> main(List<String> args) async {
  final sizes = args.isEmpty
      ? const [100, 1000, 10000, 50000]
      : args.map(int.parse).toList();
  stdout.writeln(
    'operation, requests, median ms, p95 ms, max ms  (runs=$_runs, '
    '${Platform.operatingSystem} ${Platform.version.split(' ').first})',
  );
  for (final size in sizes) {
    final dir = await Directory.systemTemp.createTemp('fetchren_bench');
    try {
      await _benchmark(dir.path, size);
    } finally {
      await dir.delete(recursive: true);
    }
  }
}

Future<void> _benchmark(String dir, int size) async {
  var local = await openLocalWorkspace(dir, clock: () => _now);
  final c = local.collection;
  final seed = Stopwatch()..start();
  await local.repository.transaction((tx) async {
    for (var i = 0; i < size; i++) {
      await tx.put(_request(c, 'seed-$i'));
    }
  });
  stdout.writeln(
    'seed ($size in one transaction), $size, '
    '${seed.elapsedMilliseconds}, -, -',
  );
  await local.close();

  await _time('open + migrate check + default collection', size, () async {
    final l = await openLocalWorkspace(dir, clock: () => _now);
    await l.close();
  });

  local = await openLocalWorkspace(dir, clock: () => _now);
  final repo = local.repository;
  await _time('children(collection)  [load list]', size, () async {
    await repo.children(c.id);
  });
  await _time('get(id)', size, () async {
    await repo.get('seed-${size ~/ 2}');
  });
  var n = 0;
  await _time('transaction: put new  [save new]', size, () async {
    await repo.transaction((tx) => tx.put(_request(c, 'new-${n++}')));
  });
  await _time('transaction: put update  [save edit]', size, () async {
    final current = (await repo.get('seed-0'))! as RequestItem;
    await repo.transaction(
      (tx) => tx.put(current.copyWith(meta: current.meta.next(_now))),
    );
  });
  var d = 1;
  await _time('transaction: softDelete  [delete]', size, () async {
    await repo.transaction((tx) => tx.softDelete('seed-${d++}', _now));
  });
  await local.close();
}

Future<void> _time(String label, int size, Future<void> Function() op) async {
  await op();
  final samples = <double>[];
  for (var i = 0; i < _runs; i++) {
    final sw = Stopwatch()..start();
    await op();
    samples.add(sw.elapsedMicroseconds / 1000);
  }
  samples.sort();
  String f(double v) => v.toStringAsFixed(2);
  stdout.writeln(
    '$label, $size, ${f(samples[_runs ~/ 2])}, '
    '${f(samples[(_runs * 0.95).floor() - 1])}, ${f(samples.last)}',
  );
}

RequestItem _request(Collection c, String id) => RequestItem(
  meta: EntityMeta.create(now: _now, sortKey: 'i', id: id),
  workspaceId: c.workspaceId,
  collectionId: c.id,
  name: 'https://api.example.test/v1/resources/$id?page=1&limit=50',
  template: RequestTemplate(
    method: HttpMethod.post,
    url: 'https://api.example.test/v1/resources/$id?page=1&limit=50',
    headers: [
      for (final (name, value) in [
        ('Accept', 'application/json'),
        ('Content-Type', 'application/json'),
        ('X-Request-Id', id),
      ])
        HeaderEntry(id: '$id-$name', name: name, value: value),
    ],
    body: '{"payload":"${'x' * 1000}"}',
  ),
);
