import 'dart:io';

import 'package:fetchren/src/models/api_request.dart';
import 'package:fetchren/src/models/http_method.dart';
import 'package:fetchren/src/storage/request_store.dart';

final DateTime fixedTime = DateTime.utc(2026, 10, 21, 12);

ApiRequest makeRequest({
  String id = 'req-1',
  HttpMethod method = HttpMethod.get,
  String url = 'https://api.example.test/items',
  List<HeaderEntry> headers = const [],
  String body = '',
  DateTime? createdAt,
  DateTime? updatedAt,
}) => ApiRequest(
  id: id,
  name: url,
  method: method,
  url: url,
  headers: headers,
  body: body,
  createdAt: createdAt ?? fixedTime,
  updatedAt: updatedAt ?? fixedTime,
);

/// In-memory [RequestStore] that records what was saved.
class InMemoryRequestStore implements RequestStore {
  InMemoryRequestStore([List<ApiRequest> initial = const []])
    : saved = [for (final r in initial) r.redactedForStorage()];

  List<ApiRequest> saved;
  int saveCount = 0;
  bool failSaves = false;
  bool failLoads = false;

  @override
  Future<StoreLoadResult> loadAll() async {
    if (failLoads) throw const FileSystemException('permission denied');
    return StoreLoadResult([...saved]);
  }

  @override
  Future<void> saveAll(List<ApiRequest> requests) async {
    if (failSaves) throw Exception('disk full');
    saveCount++;
    saved = [for (final r in requests) r.redactedForStorage()];
  }
}
