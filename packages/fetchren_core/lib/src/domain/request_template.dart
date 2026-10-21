import 'package:meta/meta.dart';

import '../models/api_request.dart' show HeaderEntry, isSensitiveHeader;
import '../models/http_method.dart';

/// The user-authored content of a request, as saved.
///
/// Values may later contain variable placeholders. A template is never sent
/// directly; it must first be turned into a [ResolvedRequest].
@immutable
class RequestTemplate {
  RequestTemplate({
    required this.method,
    required this.url,
    List<HeaderEntry> headers = const [],
    this.body = '',
  }) : headers = List.unmodifiable(headers);

  final HttpMethod method;
  final String url;
  final List<HeaderEntry> headers;
  final String body;

  RequestTemplate copyWith({
    HttpMethod? method,
    String? url,
    List<HeaderEntry>? headers,
    String? body,
  }) => RequestTemplate(
    method: method ?? this.method,
    url: url ?? this.url,
    headers: headers ?? this.headers,
    body: body ?? this.body,
  );

  /// Copy with values of sensitive headers cleared, for writing to disk.
  RequestTemplate redactedForStorage() => copyWith(
    headers: [
      for (final header in headers)
        isSensitiveHeader(header.name) ? header.copyWith(value: '') : header,
    ],
  );

  @override
  bool operator ==(Object other) =>
      other is RequestTemplate &&
      other.method == method &&
      other.url == url &&
      other.body == body &&
      _listEquals(other.headers, headers);

  @override
  int get hashCode => Object.hash(method, url, body, Object.hashAll(headers));
}

/// A send-ready request with every value final.
///
/// Only the executor consumes this type. It has no identity and no
/// serialization, so resolved values (including secrets) cannot be saved back
/// over a template by accident.
@immutable
class ResolvedRequest {
  ResolvedRequest({
    required this.method,
    required this.url,
    List<HeaderEntry> headers = const [],
    this.body = '',
  }) : headers = List.unmodifiable(headers);

  final HttpMethod method;
  final String url;
  final List<HeaderEntry> headers;
  final String body;
}

/// Turns a saved [RequestTemplate] into a [ResolvedRequest].
abstract interface class RequestResolver {
  ResolvedRequest resolve(RequestTemplate template);
}

/// Copies template values verbatim. Used until variables exist.
class LiteralRequestResolver implements RequestResolver {
  const LiteralRequestResolver();

  @override
  ResolvedRequest resolve(RequestTemplate template) => ResolvedRequest(
    method: template.method,
    url: template.url,
    headers: template.headers,
    body: template.body,
  );
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
