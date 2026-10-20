import 'dart:typed_data';

/// Categories of request failures surfaced to the user.
enum FailureKind {
  invalidUrl('Invalid URL'),
  unsupportedScheme('Unsupported URL scheme'),
  invalidHeader('Invalid header'),
  network('Network error'),
  timeout('Request timed out'),
  responseTooLarge('Response too large');

  const FailureKind(this.title);

  final String title;
}

/// Result of executing a request: either an [ApiResponse] or a [RequestFailure].
sealed class RequestOutcome {
  const RequestOutcome();
}

/// A completed HTTP exchange. Non-2xx statuses are still responses.
class ApiResponse extends RequestOutcome {
  const ApiResponse({
    required this.statusCode,
    required this.reasonPhrase,
    required this.headers,
    required this.bodyBytes,
    required this.body,
    required this.elapsed,
  });

  final int statusCode;
  final String? reasonPhrase;

  /// Response headers with lowercase names.
  final Map<String, String> headers;
  final Uint8List bodyBytes;

  /// Body decoded using the response charset, falling back to UTF-8.
  final String body;
  final Duration elapsed;

  bool get isSuccess => statusCode >= 200 && statusCode < 300;

  String? get contentType => headers['content-type'];
}

/// A request that could not be sent or whose response could not be read.
class RequestFailure extends RequestOutcome {
  const RequestFailure(this.kind, this.message, {this.elapsed});

  final FailureKind kind;
  final String message;
  final Duration? elapsed;
}
