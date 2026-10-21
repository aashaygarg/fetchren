import 'dart:convert';

import 'package:fetchren_core/fetchren_core.dart';
import 'package:http/http.dart' as http;

import 'request_outcome.dart';

/// Thrown when a request cannot be constructed from user input.
class RequestValidationException implements Exception {
  const RequestValidationException(this.kind, this.message);

  final FailureKind kind;
  final String message;

  @override
  String toString() => 'RequestValidationException($kind): $message';
}

const Set<String> supportedSchemes = {'http', 'https'};

final RegExp _headerNameToken = RegExp(r"^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$");

/// Parses and validates a request URL. Only absolute http(s) URLs are allowed.
Uri parseRequestUrl(String input) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) {
    throw const RequestValidationException(
      FailureKind.invalidUrl,
      'Enter a URL to send the request to.',
    );
  }
  final uri = Uri.tryParse(trimmed);
  if (uri == null) {
    throw const RequestValidationException(
      FailureKind.invalidUrl,
      'The URL is malformed.',
    );
  }
  if (!uri.hasScheme) {
    throw const RequestValidationException(
      FailureKind.invalidUrl,
      'The URL must start with http:// or https://.',
    );
  }
  if (!supportedSchemes.contains(uri.scheme.toLowerCase())) {
    throw RequestValidationException(
      FailureKind.unsupportedScheme,
      'Unsupported URL scheme "${uri.scheme}". Use http or https.',
    );
  }
  if (uri.host.isEmpty) {
    throw const RequestValidationException(
      FailureKind.invalidUrl,
      'The URL is missing a host name.',
    );
  }
  // dart:io throws an ArgumentError (not an Exception) for these ports.
  if (uri.hasPort && (uri.port < 1 || uri.port > 65535)) {
    throw RequestValidationException(
      FailureKind.invalidUrl,
      'Port ${uri.port} is out of range (1-65535).',
    );
  }
  return uri;
}

/// Builds the outgoing header map from enabled, non-blank rows.
///
/// Repeated names (case-insensitive) are combined with ", ".
Map<String, String> buildHeaders(Iterable<HeaderEntry> entries) {
  final headers = <String, String>{};
  final canonicalNames = <String, String>{};
  for (final entry in entries) {
    if (!entry.enabled || entry.isBlank) continue;
    final name = entry.name.trim();
    if (name.isEmpty) {
      throw const RequestValidationException(
        FailureKind.invalidHeader,
        'A header has a value but no name.',
      );
    }
    if (!_headerNameToken.hasMatch(name)) {
      throw RequestValidationException(
        FailureKind.invalidHeader,
        'Header name "$name" contains invalid characters.',
      );
    }
    final value = entry.value.trim();
    // Rejecting CR/LF/NUL prevents header injection; dart:io only sends Latin-1.
    if (value.codeUnits.any((c) => c == 0x0A || c == 0x0D || c == 0x00)) {
      throw RequestValidationException(
        FailureKind.invalidHeader,
        'The value of header "$name" contains a line break.',
      );
    }
    if (value.codeUnits.any((c) => c > 0xFF)) {
      throw RequestValidationException(
        FailureKind.invalidHeader,
        'The value of header "$name" contains unsupported characters.',
      );
    }
    final key = name.toLowerCase();
    final existingName = canonicalNames[key];
    if (existingName == null) {
      canonicalNames[key] = name;
      headers[name] = value;
    } else {
      headers[existingName] = '${headers[existingName]}, $value';
    }
  }
  return headers;
}

/// Converts a [ResolvedRequest] into an abortable `package:http` request.
///
/// The body is only attached for methods that allow one. No Content-Type is
/// added automatically; the user controls all headers. Redirects are returned
/// to the caller rather than followed, because dart:io forwards custom
/// credential headers (e.g. `X-API-Key`) to cross-origin redirect targets.
http.AbortableRequest buildHttpRequest(
  ResolvedRequest request, {
  Future<void>? abortTrigger,
}) {
  final uri = parseRequestUrl(request.url);
  final headers = buildHeaders(request.headers);
  final httpRequest =
      http.AbortableRequest(
          request.method.wireName,
          uri,
          abortTrigger: abortTrigger,
        )
        ..followRedirects = false
        ..headers.addAll(headers);
  if (request.method.allowsBody && request.body.isNotEmpty) {
    httpRequest.bodyBytes = utf8.encode(request.body);
  }
  return httpRequest;
}
