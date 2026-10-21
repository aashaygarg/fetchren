/// Platform-independent domain model and contracts for FetchRen.
///
/// Must not depend on Flutter or `dart:io`.
library;

export 'src/domain/entity_meta.dart';
export 'src/domain/request_template.dart';
export 'src/domain/sort_key.dart';
export 'src/domain/workspace_entities.dart';
export 'src/migration/legacy_v1_migration.dart';
export 'src/models/api_request.dart';
export 'src/models/http_method.dart';
export 'src/repository/in_memory_workspace_repository.dart';
export 'src/repository/workspace_repository.dart';
export 'src/repository/workspace_rules.dart';
