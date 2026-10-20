import 'dart:convert';
import 'dart:io';

import '../models/api_request.dart';

/// Result of loading saved requests.
class StoreLoadResult {
  const StoreLoadResult(this.requests, {this.recoveredCorruptFile});

  final List<ApiRequest> requests;

  /// Set when an unreadable store file was moved aside to this path.
  final String? recoveredCorruptFile;
}

/// Persists saved requests.
abstract interface class RequestStore {
  Future<StoreLoadResult> loadAll();

  /// Replaces all saved requests. Sensitive header values are not written.
  Future<void> saveAll(List<ApiRequest> requests);
}

/// Stores requests as a versioned JSON document in a single local file.
///
/// The file is plain text and not encrypted. Writes go to a temporary file
/// first and are then renamed into place.
class FileRequestStore implements RequestStore {
  FileRequestStore(this.file);

  static const int schemaVersion = 1;

  final File file;
  Future<void> _pendingWrite = Future.value();

  @override
  Future<StoreLoadResult> loadAll() async {
    if (!await file.exists()) return const StoreLoadResult([]);
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, Object?> ||
          decoded['version'] != schemaVersion ||
          decoded['requests'] is! List<Object?>) {
        throw const FormatException('Unrecognized store format');
      }
      final requests = [
        for (final item in decoded['requests'] as List<Object?>)
          if (item is Map<String, Object?>)
            ApiRequest.fromJson(item)
          else
            throw const FormatException('Invalid request entry'),
      ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return StoreLoadResult(requests);
    } on FormatException {
      final backup = File(
        '${file.path}.corrupt-${DateTime.now().millisecondsSinceEpoch}',
      );
      await file.rename(backup.path);
      return StoreLoadResult(const [], recoveredCorruptFile: backup.path);
    }
  }

  @override
  Future<void> saveAll(List<ApiRequest> requests) {
    final payload = const JsonEncoder.withIndent('  ').convert({
      'version': schemaVersion,
      'requests': [
        for (final request in requests) request.redactedForStorage().toJson(),
      ],
    });
    // Serialize writes so an older snapshot never lands after a newer one.
    final write = _pendingWrite.then((_) => _write(payload));
    _pendingWrite = write.catchError((Object _) {});
    return write;
  }

  Future<void> _write(String payload) async {
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(payload, flush: true);
    await temp.rename(file.path);
  }
}
