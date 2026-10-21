import 'dart:math';

import 'package:meta/meta.dart';

import 'http_method.dart';

final Random _random = Random.secure();

/// Returns a random 128-bit identifier encoded as 32 lowercase hex characters.
String generateId() {
  final buffer = StringBuffer();
  for (var i = 0; i < 16; i++) {
    buffer.write(_random.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

/// Header names whose values are treated as credentials and never persisted.
const Set<String> sensitiveHeaderNames = {
  'authorization',
  'proxy-authorization',
  'cookie',
  'set-cookie',
  'x-api-key',
  'api-key',
  'x-auth-token',
};

bool isSensitiveHeader(String name) =>
    sensitiveHeaderNames.contains(name.trim().toLowerCase());

@immutable
class HeaderEntry {
  const HeaderEntry({
    required this.id,
    this.name = '',
    this.value = '',
    this.enabled = true,
  });

  factory HeaderEntry.create({String name = '', String value = ''}) =>
      HeaderEntry(id: generateId(), name: name, value: value);

  factory HeaderEntry.fromJson(Map<String, Object?> json) => HeaderEntry(
    id: _read<String>(json, 'id'),
    name: _read<String>(json, 'name'),
    value: _read<String>(json, 'value'),
    enabled: _read<bool>(json, 'enabled'),
  );

  final String id;
  final String name;
  final String value;
  final bool enabled;

  /// True when the row has neither a name nor a value.
  bool get isBlank => name.trim().isEmpty && value.isEmpty;

  HeaderEntry copyWith({String? name, String? value, bool? enabled}) =>
      HeaderEntry(
        id: id,
        name: name ?? this.name,
        value: value ?? this.value,
        enabled: enabled ?? this.enabled,
      );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'value': value,
    'enabled': enabled,
  };

  @override
  bool operator ==(Object other) =>
      other is HeaderEntry &&
      other.id == id &&
      other.name == name &&
      other.value == value &&
      other.enabled == enabled;

  @override
  int get hashCode => Object.hash(id, name, value, enabled);
}

/// A saved request in the schema-v1 `requests.json` format.
///
/// Superseded by `RequestItem`; kept until storage moves to the workspace model.
@immutable
class ApiRequest {
  ApiRequest({
    required this.id,
    required this.name,
    required this.method,
    required this.url,
    required List<HeaderEntry> headers,
    required this.body,
    required this.createdAt,
    required this.updatedAt,
  }) : headers = List.unmodifiable(headers);

  factory ApiRequest.fromJson(Map<String, Object?> json) {
    final rawHeaders = _read<List<Object?>>(json, 'headers');
    return ApiRequest(
      id: _read<String>(json, 'id'),
      name: _read<String>(json, 'name'),
      method: HttpMethod.fromWireName(_read<String>(json, 'method')),
      url: _read<String>(json, 'url'),
      headers: [
        for (final header in rawHeaders)
          if (header is Map<String, Object?>)
            HeaderEntry.fromJson(header)
          else
            throw const FormatException('Invalid header entry'),
      ],
      body: _read<String>(json, 'body'),
      createdAt: _readTimestamp(json, 'createdAt'),
      updatedAt: _readTimestamp(json, 'updatedAt'),
    );
  }

  final String id;
  final String name;
  final HttpMethod method;
  final String url;
  final List<HeaderEntry> headers;
  final String body;
  final DateTime createdAt;
  final DateTime updatedAt;

  ApiRequest copyWith({
    String? name,
    HttpMethod? method,
    String? url,
    List<HeaderEntry>? headers,
    String? body,
    DateTime? updatedAt,
  }) => ApiRequest(
    id: id,
    name: name ?? this.name,
    method: method ?? this.method,
    url: url ?? this.url,
    headers: headers ?? this.headers,
    body: body ?? this.body,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  /// Copy with values of sensitive headers cleared, for writing to disk.
  ApiRequest redactedForStorage() => copyWith(
    headers: [
      for (final header in headers)
        isSensitiveHeader(header.name) ? header.copyWith(value: '') : header,
    ],
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'method': method.wireName,
    'url': url,
    'headers': [for (final header in headers) header.toJson()],
    'body': body,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };
}

T _read<T>(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is T) return value;
  throw FormatException('Missing or invalid "$key"');
}

DateTime _readTimestamp(Map<String, Object?> json, String key) {
  final parsed = DateTime.tryParse(_read<String>(json, key));
  if (parsed == null) throw FormatException('Invalid timestamp "$key"');
  return parsed.toUtc();
}
