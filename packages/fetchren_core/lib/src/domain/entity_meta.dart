import 'package:meta/meta.dart';

import '../models/api_request.dart' show generateId;
import 'sort_key.dart';

/// Metadata carried by every workspace entity.
///
/// [version] is a local revision counter: 1 on creation, +1 on every change.
/// Deletion is a tombstone ([deletedAt]) so it can propagate to other
/// replicas later; purging tombstones is a separate, future operation.
@immutable
class EntityMeta {
  EntityMeta({
    required this.id,
    required DateTime createdAt,
    required DateTime updatedAt,
    required this.version,
    required this.sortKey,
    DateTime? deletedAt,
  }) : createdAt = createdAt.toUtc(),
       updatedAt = updatedAt.toUtc(),
       deletedAt = deletedAt?.toUtc() {
    if (id.isEmpty) throw ArgumentError.value(id, 'id', 'Must not be empty');
    if (version < 1) {
      throw ArgumentError.value(version, 'version', 'Must be at least 1');
    }
    if (!isValidSortKey(sortKey)) {
      throw ArgumentError.value(sortKey, 'sortKey', 'Invalid sort key');
    }
    if (this.updatedAt.isBefore(this.createdAt)) {
      throw ArgumentError('updatedAt must not precede createdAt');
    }
  }

  /// Metadata for a new entity. Pass [id] to preserve an existing identifier.
  factory EntityMeta.create({
    required DateTime now,
    required String sortKey,
    String? id,
  }) => EntityMeta(
    id: id ?? generateId(),
    createdAt: now,
    updatedAt: now,
    version: 1,
    sortKey: sortKey,
  );

  final String id;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int version;
  final String sortKey;
  final DateTime? deletedAt;

  bool get isDeleted => deletedAt != null;

  /// The next revision of this entity, changed at [now].
  EntityMeta next(DateTime now, {String? sortKey}) => EntityMeta(
    id: id,
    createdAt: createdAt,
    updatedAt: _notBefore(now, updatedAt),
    version: version + 1,
    sortKey: sortKey ?? this.sortKey,
    deletedAt: deletedAt,
  );

  /// The next revision, marked deleted at [now].
  EntityMeta deleted(DateTime now) {
    final at = _notBefore(now, updatedAt);
    return EntityMeta(
      id: id,
      createdAt: createdAt,
      updatedAt: at,
      version: version + 1,
      sortKey: sortKey,
      deletedAt: at,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is EntityMeta &&
      other.id == id &&
      other.createdAt == createdAt &&
      other.updatedAt == updatedAt &&
      other.version == version &&
      other.sortKey == sortKey &&
      other.deletedAt == deletedAt;

  @override
  int get hashCode =>
      Object.hash(id, createdAt, updatedAt, version, sortKey, deletedAt);

  @override
  String toString() => 'EntityMeta($id v$version)';
}

// Clock skew must never make updatedAt move backwards.
DateTime _notBefore(DateTime now, DateTime floor) {
  final utc = now.toUtc();
  return utc.isBefore(floor) ? floor : utc;
}
