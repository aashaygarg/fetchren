import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fetchren_core/fetchren_core.dart';
import 'package:http/http.dart' as http;

import '../util/format.dart';
import 'request_builder.dart';
import 'request_outcome.dart';

/// Executes [ResolvedRequest]s directly against the target server.
///
/// Never logs request headers or bodies. TLS verification is left to the
/// platform defaults of the injected [http.Client].
class RequestExecutor {
  RequestExecutor(
    this._client, {
    this.timeout = defaultTimeout,
    this.maxResponseBytes = defaultMaxResponseBytes,
  });

  static const Duration defaultTimeout = Duration(seconds: 30);
  static const int defaultMaxResponseBytes = 10 * 1024 * 1024;

  final http.Client _client;

  /// Deadline for the whole exchange, including reading the response body.
  Duration timeout;

  /// Responses larger than this are aborted.
  int maxResponseBytes;

  Future<RequestOutcome> execute(ResolvedRequest request) async {
    final abort = Completer<void>();
    final http.BaseRequest httpRequest;
    try {
      httpRequest = buildHttpRequest(request, abortTrigger: abort.future);
    } on RequestValidationException catch (e) {
      return RequestFailure(e.kind, e.message);
    }

    final stopwatch = Stopwatch()..start();
    try {
      return await _exchange(
        httpRequest,
        stopwatch,
        abort.future,
      ).timeout(timeout);
    } on TimeoutException {
      return RequestFailure(
        FailureKind.timeout,
        'No complete response within ${formatDuration(timeout)}.',
        elapsed: stopwatch.elapsed,
      );
    } on _ResponseTooLarge {
      return _tooLarge(stopwatch.elapsed);
    } on http.ClientException catch (e) {
      return RequestFailure(
        FailureKind.network,
        e.message,
        elapsed: stopwatch.elapsed,
      );
    } on Exception catch (e) {
      // Covers TLS handshake and other transport errors not wrapped by http.
      return RequestFailure(
        FailureKind.network,
        e.toString(),
        elapsed: stopwatch.elapsed,
      );
    } finally {
      // Cancels the underlying connection if the exchange was abandoned.
      if (!abort.isCompleted) abort.complete();
    }
  }

  Future<RequestOutcome> _exchange(
    http.BaseRequest request,
    Stopwatch stopwatch,
    Future<void> abort,
  ) async {
    final response = await _client.send(request);
    final declaredLength = response.contentLength;
    if (declaredLength != null && declaredLength > maxResponseBytes) {
      unawaited(response.stream.listen(null).cancel());
      return _tooLarge(stopwatch.elapsed);
    }
    final bytes = await _readBody(response.stream, abort);
    stopwatch.stop();
    return ApiResponse(
      statusCode: response.statusCode,
      reasonPhrase: response.reasonPhrase,
      headers: response.headers,
      bodyBytes: bytes,
      body: decodeBody(bytes, response.headers['content-type']),
      elapsed: stopwatch.elapsed,
    );
  }

  Future<Uint8List> _readBody(Stream<List<int>> stream, Future<void> abort) {
    final completer = Completer<Uint8List>();
    final builder = BytesBuilder(copy: false);
    late final StreamSubscription<List<int>> subscription;
    subscription = stream.listen(
      (chunk) {
        if (completer.isCompleted) return;
        builder.add(chunk);
        if (builder.length > maxResponseBytes) {
          completer.completeError(const _ResponseTooLarge());
          unawaited(subscription.cancel());
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!completer.isCompleted) completer.completeError(error, stackTrace);
      },
      onDone: () {
        if (!completer.isCompleted) completer.complete(builder.takeBytes());
      },
      cancelOnError: true,
    );
    unawaited(abort.then((_) => subscription.cancel()));
    return completer.future;
  }

  RequestFailure _tooLarge(Duration elapsed) => RequestFailure(
    FailureKind.responseTooLarge,
    'The response exceeded the ${formatBytes(maxResponseBytes)} limit '
    'and was discarded.',
    elapsed: elapsed,
  );
}

class _ResponseTooLarge implements Exception {
  const _ResponseTooLarge();
}

final RegExp _charsetPattern = RegExp(
  r'charset\s*=\s*"?([^\s;"]+)',
  caseSensitive: false,
);

/// Decodes [bytes] using the charset in [contentType], defaulting to UTF-8.
/// Malformed input never throws; invalid sequences become U+FFFD.
String decodeBody(List<int> bytes, String? contentType) {
  final charset = contentType == null
      ? null
      : _charsetPattern.firstMatch(contentType)?.group(1);
  final encoding = charset == null ? null : Encoding.getByName(charset);
  if (encoding != null && encoding != utf8) {
    try {
      return encoding.decode(bytes);
    } on FormatException {
      // Fall through to lenient UTF-8.
    }
  }
  return utf8.decode(bytes, allowMalformed: true);
}
