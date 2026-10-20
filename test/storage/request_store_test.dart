import 'dart:convert';
import 'dart:io';

import 'package:fetchren/src/models/api_request.dart';
import 'package:fetchren/src/models/http_method.dart';
import 'package:fetchren/src/storage/request_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fakes.dart';

void main() {
  late Directory dir;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('fetchren_store_test');
    file = File('${dir.path}/nested/requests.json');
  });

  tearDown(() => dir.delete(recursive: true));

  test('returns an empty list when no file exists', () async {
    final result = await FileRequestStore(file).loadAll();
    expect(result.requests, isEmpty);
    expect(result.recoveredCorruptFile, isNull);
  });

  test('round-trips requests across store instances (app restart)', () async {
    final created = DateTime.utc(2026, 1, 2, 3, 4, 5);
    final updated = DateTime.utc(2026, 2, 3, 4, 5, 6);
    final original = makeRequest(
      id: 'abc',
      method: HttpMethod.patch,
      url: 'https://api.example.test/x',
      headers: const [
        HeaderEntry(id: 'h1', name: 'Accept', value: 'application/json'),
        HeaderEntry(id: 'h2', name: 'X-Off', value: 'v', enabled: false),
      ],
      body: '{"k":"v"}',
      createdAt: created,
      updatedAt: updated,
    );

    await FileRequestStore(file).saveAll([original]);
    final loaded = (await FileRequestStore(file).loadAll()).requests.single;

    expect(loaded.id, 'abc');
    expect(loaded.method, HttpMethod.patch);
    expect(loaded.url, original.url);
    expect(loaded.headers, original.headers);
    expect(loaded.body, original.body);
    expect(loaded.createdAt, created);
    expect(loaded.updatedAt, updated);
  });

  test('loads requests most recently updated first', () async {
    await FileRequestStore(file).saveAll([
      makeRequest(id: 'old', updatedAt: DateTime.utc(2026)),
      makeRequest(id: 'new', updatedAt: DateTime.utc(2027)),
    ]);
    final ids = (await FileRequestStore(
      file,
    ).loadAll()).requests.map((r) => r.id);
    expect(ids, ['new', 'old']);
  });

  test('does not write sensitive header values to disk', () async {
    await FileRequestStore(file).saveAll([
      makeRequest(
        headers: const [
          HeaderEntry(id: '1', name: 'Authorization', value: 'Bearer s3cret'),
          HeaderEntry(id: '2', name: 'cookie', value: 'session=s3cret'),
          HeaderEntry(id: '3', name: 'X-API-Key', value: 's3cret'),
          HeaderEntry(id: '4', name: 'Accept', value: 'text/plain'),
        ],
      ),
    ]);

    final contents = await file.readAsString();
    expect(contents, isNot(contains('s3cret')));
    final headers = (await FileRequestStore(
      file,
    ).loadAll()).requests.single.headers;
    expect(headers.map((h) => h.name), [
      'Authorization',
      'cookie',
      'X-API-Key',
      'Accept',
    ]);
    expect(headers.map((h) => h.value), ['', '', '', 'text/plain']);
  });

  test('writes a versioned document and leaves no temp file', () async {
    await FileRequestStore(file).saveAll([makeRequest()]);
    final json = jsonDecode(await file.readAsString()) as Map<String, Object?>;
    expect(json['version'], FileRequestStore.schemaVersion);
    expect(json['requests'], hasLength(1));
    expect(File('${file.path}.tmp').existsSync(), isFalse);
  });

  test('serializes concurrent writes so the last save wins', () async {
    final store = FileRequestStore(file);
    await Future.wait([
      store.saveAll([makeRequest(id: 'first')]),
      store.saveAll([makeRequest(id: 'second')]),
    ]);
    final loaded = await FileRequestStore(file).loadAll();
    expect(loaded.requests.single.id, 'second');
  });

  test('moves an unreadable file aside instead of overwriting it', () async {
    await file.parent.create(recursive: true);
    await file.writeAsString('{not json');

    final result = await FileRequestStore(file).loadAll();

    expect(result.requests, isEmpty);
    final backup = result.recoveredCorruptFile;
    expect(backup, isNotNull);
    expect(await File(backup!).readAsString(), '{not json');
    expect(file.existsSync(), isFalse);
  });

  test('treats unknown schema versions and bad entries as corrupt', () async {
    await file.parent.create(recursive: true);
    for (final contents in [
      jsonEncode({'version': 99, 'requests': []}),
      jsonEncode({
        'version': 1,
        'requests': [
          {'id': 'x'},
        ],
      }),
      jsonEncode({
        'version': 1,
        'requests': [
          {...makeRequest().toJson(), 'method': 'TRACE'},
        ],
      }),
    ]) {
      await file.writeAsString(contents);
      final result = await FileRequestStore(file).loadAll();
      expect(result.recoveredCorruptFile, isNotNull, reason: contents);
    }
  });
}
