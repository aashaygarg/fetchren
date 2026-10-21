import 'dart:convert';

import '../domain/entity_meta.dart';
import '../domain/request_template.dart';
import '../domain/sort_key.dart';
import '../domain/workspace_entities.dart';
import '../models/api_request.dart';
import '../repository/workspace_repository.dart';

const String defaultWorkspaceName = 'My Workspace';
const String defaultCollectionName = 'Saved requests';
const String untitledRequestName = 'Untitled request';

/// Result of parsing a schema-v1 `requests.json` document.
class LegacyV1ParseResult {
  LegacyV1ParseResult(List<ApiRequest> requests, List<String> errors)
    : requests = List.unmodifiable(requests),
      errors = List.unmodifiable(errors);

  /// Every entry that parsed successfully, in file order.
  final List<ApiRequest> requests;

  /// One message per problem. Non-empty means the file must not be migrated.
  final List<String> errors;

  bool get isValid => errors.isEmpty;
}

/// Parses a schema-v1 document, reporting every malformed or duplicate entry.
///
/// Never throws for bad input and never drops an entry silently.
LegacyV1ParseResult parseLegacyV1(String source) {
  final Object? decoded;
  try {
    decoded = jsonDecode(source);
  } on FormatException catch (e) {
    return LegacyV1ParseResult(const [], ['Not valid JSON: ${e.message}']);
  }
  if (decoded is! Map<String, Object?>) {
    return LegacyV1ParseResult(const [], ['Top level is not a JSON object']);
  }
  if (decoded['version'] != 1) {
    return LegacyV1ParseResult(const [], [
      'Unsupported version: ${decoded['version']}',
    ]);
  }
  final entries = decoded['requests'];
  if (entries is! List<Object?>) {
    return LegacyV1ParseResult(const [], ['"requests" is not a list']);
  }

  final requests = <ApiRequest>[];
  final errors = <String>[];
  final firstIndexById = <String, int>{};
  for (final (i, entry) in entries.indexed) {
    if (entry is! Map<String, Object?>) {
      errors.add('Entry $i: not a JSON object');
      continue;
    }
    final ApiRequest request;
    try {
      request = ApiRequest.fromJson(entry);
    } on FormatException catch (e) {
      errors.add('Entry $i: ${e.message}');
      continue;
    }
    if (request.id.trim().isEmpty) {
      errors.add('Entry $i: blank ID');
      continue;
    }
    final first = firstIndexById[request.id];
    if (first != null) {
      errors.add('Entry $i: duplicate ID ${request.id} (also entry $first)');
      continue;
    }
    firstIndexById[request.id] = i;
    requests.add(request);
  }
  return LegacyV1ParseResult(requests, errors);
}

/// The workspace records produced from schema-v1 saved requests.
class LegacyV1MigrationPlan {
  LegacyV1MigrationPlan({
    required List<RequestItem> requests,
    required List<String> warnings,
  }) : requests = List.unmodifiable(requests),
       warnings = List.unmodifiable(warnings);

  /// One item per legacy request, in the legacy display order.
  final List<RequestItem> requests;

  /// Values that had to be repaired, for reporting to the user.
  final List<String> warnings;
}

/// Maps schema-v1 requests into [target].
///
/// Request IDs, names, contents, and timestamps are preserved. Order follows
/// the v1 sidebar (most recently updated first); sort keys start after
/// [afterSortKey] so existing siblings keep theirs. Duplicate IDs throw a
/// [FormatException] rather than dropping a record.
LegacyV1MigrationPlan planLegacyV1Migration(
  List<ApiRequest> legacy, {
  required Collection target,
  String? afterSortKey,
}) {
  final seen = <String>{};
  for (final request in legacy) {
    if (!seen.add(request.id)) {
      throw FormatException('Duplicate request ID ${request.id}');
    }
  }

  final ordered = [...legacy]
    ..sort((a, b) {
      final byUpdated = b.updatedAt.compareTo(a.updatedAt);
      return byUpdated != 0 ? byUpdated : a.id.compareTo(b.id);
    });
  final keys = sortKeysAfter(afterSortKey, ordered.length);
  final warnings = <String>[];

  final requests = [
    for (final (i, request) in ordered.indexed)
      RequestItem(
        meta: EntityMeta(
          id: request.id,
          createdAt: request.createdAt,
          updatedAt: _repairUpdatedAt(request, warnings),
          version: 1,
          sortKey: keys[i],
        ),
        workspaceId: target.workspaceId,
        collectionId: target.id,
        name: _repairName(request, warnings),
        template: RequestTemplate(
          method: request.method,
          url: request.url,
          headers: request.headers,
          body: request.body,
        ),
      ),
  ];

  return LegacyV1MigrationPlan(requests: requests, warnings: warnings);
}

/// Writes every item of [plan] with [tx].
///
/// Run inside one transaction so a failure leaves nothing behind.
Future<void> writeLegacyV1Plan(
  WorkspaceWriter tx,
  LegacyV1MigrationPlan plan,
) async {
  for (final request in plan.requests) {
    await tx.put(request);
  }
}

/// Returns the first live collection of the first live workspace, creating
/// "My Workspace" / "Saved requests" if either is missing.
///
/// Safe to call concurrently: the lookup and creation share a transaction.
Future<Collection> ensureDefaultCollection(
  WorkspaceRepository repository, {
  required DateTime now,
}) => repository.transaction((tx) async {
  final workspaces = await tx.workspaces();
  final workspace = workspaces.isNotEmpty
      ? workspaces.first
      : Workspace(
          meta: EntityMeta.create(
            now: now,
            sortKey: sortKeyBetween(null, null),
          ),
          name: defaultWorkspaceName,
        );
  if (workspaces.isEmpty) await tx.put(workspace);

  for (final child in await tx.children(workspace.id)) {
    if (child is Collection) return child;
  }
  final collection = Collection(
    meta: EntityMeta.create(now: now, sortKey: sortKeyBetween(null, null)),
    workspaceId: workspace.id,
    name: defaultCollectionName,
  );
  await tx.put(collection);
  return collection;
});

DateTime _repairUpdatedAt(ApiRequest request, List<String> warnings) {
  if (!request.updatedAt.isBefore(request.createdAt)) return request.updatedAt;
  warnings.add('${request.id}: updatedAt preceded createdAt; set to createdAt');
  return request.createdAt;
}

String _repairName(ApiRequest request, List<String> warnings) {
  if (request.name.trim().isNotEmpty) return request.name;
  warnings.add(
    '${request.id}: blank name replaced with "$untitledRequestName"',
  );
  return untitledRequestName;
}
